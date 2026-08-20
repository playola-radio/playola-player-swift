//  SampleBufferStationRendererTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane D. The render-driver core through the fake seam, run
//  synchronously via ImmediateControlExecutor: fill-loop enqueue/PTS/no-backfill,
//  boundary -> spin-start (T12), generation supersession (T6), dynamic append
//  (beyond-horizon vs late-ignored), snapshot replacement, and pause-refill-resume
//  recovery after an AirPlay auto-flush (§13/C2).

import CoreMedia
import Foundation
import Testing

@testable import PlayolaPlayer

private struct StubMixSource: MixSource {
  let startFrame: Int64
  let envelope: FadeEnvelope
  let value: SIMD2<Float>

  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>? {
    offset >= 0 ? value : nil
  }
}

@MainActor
struct SampleBufferStationRendererTests {
  private let sampleRate: Double = 48_000
  private let framesPerBuffer = 4_096

  private func makeRenderer(
    sync: FakeRenderSynchronizer, sink: FakeSampleBufferRenderer, startFrame: Int64 = 0
  ) -> SampleBufferStationRenderer {
    SampleBufferStationRenderer(
      synchronizer: sync,
      renderer: sink,
      mixer: TimelineMixer(sampleRate: sampleRate),
      startFrame: startFrame,
      sampleRate: sampleRate,
      framesPerBuffer: framesPerBuffer,
      control: ImmediateControlExecutor(),
      enqueueAheadSeconds: 1.0)  // deterministic 1s window for the frame assertions below
  }

  private func unity(_ volume: Float = 1.0) -> FadeEnvelope {
    FadeEnvelope(spin: Spin.mockWith(startingVolume: volume, fades: []))
  }

  private func stub(startFrame: Int64, value: SIMD2<Float> = SIMD2(0.5, 0.5)) -> StubMixSource {
    StubMixSource(startFrame: startFrame, envelope: unity(), value: value)
  }

  @Test("fill enqueues contiguous buffers with monotonic sample-accurate PTS")
  func fillEnqueuesContiguousBuffers() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    renderer.setSchedule([.init(spin: Spin.mockWith(), source: stub(startFrame: 0))])
    renderer.start()
    sink.pump()

    #expect(!sink.enqueued.isEmpty)
    for (i, buffer) in sink.enqueued.enumerated() {
      #expect(buffer.startFrame == Int64(i * framesPerBuffer))
      #expect(buffer.frameCount == framesPerBuffer)
    }
    #expect(sink.enqueued.last!.startFrame < 48_000)
    #expect(CMTimeGetSeconds(sink.enqueued[0].presentationTimeStamp) == 0)
  }

  @Test("fill never enqueues buffers whose PTS is behind the playhead")
  func fillNeverBackfills() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    renderer.setSchedule([.init(spin: Spin.mockWith(), source: stub(startFrame: 0))])
    sync.currentTime = CMTime(seconds: 1, preferredTimescale: Int32(sampleRate))
    renderer.start()
    sink.pump()

    #expect(!sink.enqueued.isEmpty)
    #expect(sink.enqueued.allSatisfy { $0.startFrame >= 48_000 })
  }

  @Test("a latency-compensated start frame shifts the anchor and the first authored PTS")
  func latencyCompensatedStart() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let latencyFrames: Int64 = 96_000  // 2s @ 48k (e.g. AirPlay), fed as the start frame
    let renderer = makeRenderer(sync: sync, sink: sink, startFrame: latencyFrames)
    renderer.setSchedule([.init(spin: Spin.mockWith(), source: stub(startFrame: 0))])
    renderer.start()
    // The timebase is anchored at the shifted frame; model that so fill isn't gated as "behind".
    sync.currentTime = CMTime(value: latencyFrames, timescale: Int32(sampleRate))
    sink.pump()

    #expect(sync.setRateCalls.first.map { CMTimeGetSeconds($0.time) } == 2.0)  // anchored 2s ahead
    #expect(sink.enqueued.first?.startFrame == latencyFrames)  // authored from the shifted frame
  }

  @Test("boundary observers install on the renderer timeline (source start + timebase lead)")
  func boundaryObserversCompensateTimebaseLead() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let latencyFrames: Int64 = 96_000  // 2s @ 48k — the timebase's head start over the acoustic timeline
    let renderer = makeRenderer(sync: sync, sink: sink, startFrame: latencyFrames)
    renderer.setSchedule([.init(spin: Spin.mockWith(), source: stub(startFrame: 480_000))])

    // The spin becomes AUDIBLE when the timebase (running latencyFrames ahead of the speaker) reaches
    // startFrame + latencyFrames. Observing at bare startFrame would flip `.playing` ~2s early on AirPlay.
    #expect(
      sync.installedBoundaryTimes.map { CMTimeGetSeconds($0) }
        == [Double(480_000 + latencyFrames) / sampleRate])
  }

  @Test("a crossed boundary reports the spin start once")
  func boundaryReportsSpinStart() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    var started: [String] = []
    renderer.onSpinStarted = { started.append($0.id) }
    renderer.setSchedule([.init(spin: Spin.mockWith(id: "spin-A"), source: stub(startFrame: 0))])
    renderer.start()

    sync.fireBoundary()
    sync.fireBoundary()  // idempotent

    #expect(started == ["spin-A"])
  }

  @Test("a superseded generation never publishes a spin start")
  func supersededGenerationDoesNotPublish() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    var started: [String] = []
    renderer.onSpinStarted = { started.append($0.id) }
    renderer.setSchedule([.init(spin: Spin.mockWith(id: "spin-A"), source: stub(startFrame: 0))])
    renderer.start()

    renderer.supersede()
    sync.fireBoundary()

    #expect(started.isEmpty)
  }

  @Test("a spin scheduled beyond the enqueue horizon is appended and reports its boundary")
  func appendBeyondHorizonAdds() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    var started: [String] = []
    renderer.onSpinStarted = { started.append($0.id) }
    renderer.setSchedule([.init(spin: Spin.mockWith(id: "spin-A"), source: stub(startFrame: 0))])
    renderer.start()
    sink.pump()  // advance the write cursor past the enqueue horizon

    // Well past the write cursor → clean append.
    renderer.appendScheduled([
      .init(spin: Spin.mockWith(id: "spin-B"), source: stub(startFrame: 100_000))
    ])
    sync.fireBoundary()

    #expect(started.contains("spin-B"))
  }

  @Test("a spin landing inside the enqueue horizon is not appended (late-ignored)")
  func appendInsideHorizonIgnored() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    var started: [String] = []
    var ignored: [String] = []
    renderer.onSpinStarted = { started.append($0.id) }
    renderer.onLateSpinIgnored = { ignored.append($0.id) }
    renderer.setSchedule([.init(spin: Spin.mockWith(id: "spin-A"), source: stub(startFrame: 0))])
    renderer.start()
    sink.pump()  // write cursor advances past frame 1000

    // Frame 1000 is now behind the write cursor (already enqueued) → no in-place surgery in slice 1.
    renderer.appendScheduled([
      .init(spin: Spin.mockWith(id: "spin-C"), source: stub(startFrame: 1_000))
    ])
    sync.fireBoundary()

    #expect(ignored == ["spin-C"])
    #expect(!started.contains("spin-C"))
  }

  @Test("updateSnapshot replaces a spin's render source")
  func updateSnapshotReplacesSource() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    // Start silent, then publish a decoded window carrying audio.
    renderer.setSchedule([
      .init(spin: Spin.mockWith(id: "spin-A"), source: stub(startFrame: 0, value: SIMD2(0, 0)))
    ])
    renderer.start()

    let window = SpinPCMWindow(
      spinID: "spin-A", startFrame: 0, envelope: unity(), windowStart: 0,
      frames: Array(repeating: SIMD2(0.5, 0.5), count: framesPerBuffer))
    renderer.updateSnapshot(window)
    sink.pump()

    #expect(!sink.enqueued.isEmpty)
    #expect(abs(sink.enqueued[0].frames[0].x - 0.5) < 0.0001)
  }

  @Test("recovery re-anchors to the playhead and refills, without a manual flush or setRate")
  func recoveryReanchorsAndRefills() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    renderer.setSchedule([.init(spin: Spin.mockWith(), source: stub(startFrame: 0))])
    renderer.start()
    sink.pump()
    let flushesBefore = sink.flushCount
    let setRatesBefore = sync.setRateCalls.count

    sync.currentTime = CMTime(seconds: 2, preferredTimescale: Int32(sampleRate))  // timebase advanced
    renderer.recoverAfterAutoFlush()

    // Refilled from where the timebase actually is (no backfill) …
    #expect(sink.enqueued.contains { $0.startFrame == 96_000 })
    // … and did NOT thrash the renderer (no manual flush; rate already 1.0 so no re-issue).
    #expect(sink.flushCount == flushesBefore)
    #expect(sync.setRateCalls.count == setRatesBefore)
  }

  @Test("recovery resumes the timebase only if it was paused")
  func recoveryResumesOnlyIfPaused() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    renderer.setSchedule([.init(spin: Spin.mockWith(), source: stub(startFrame: 0))])
    renderer.start()
    sink.pump()

    sync.currentTime = CMTime(seconds: 2, preferredTimescale: Int32(sampleRate))
    sync.rate = 0  // an auto-flush left the synchronizer paused
    renderer.recoverAfterAutoFlush()

    let resume = sync.setRateCalls.last
    #expect(resume?.rate == 1.0)
    #expect(resume.map { CMTimeGetSeconds($0.time) } == 2.0)  // resume at the current time
  }

  @Test("stop tears down: no further boundary publishes, sink stopped and flushed")
  func stopTearsDown() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    var started: [String] = []
    renderer.onSpinStarted = { started.append($0.id) }
    renderer.setSchedule([.init(spin: Spin.mockWith(id: "spin-A"), source: stub(startFrame: 0))])
    renderer.start()

    renderer.stop()
    sync.fireBoundary()

    #expect(started.isEmpty)
    #expect(sink.stopRequestCount >= 1)
    #expect(sink.flushCount >= 1)
  }
}
