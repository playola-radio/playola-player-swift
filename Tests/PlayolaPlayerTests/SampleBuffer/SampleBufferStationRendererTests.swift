//  SampleBufferStationRendererTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane D. The render-driver core through the fake seam: fill-loop
//  enqueue/PTS, boundary -> spin-start (T12), generation supersession (T6), and
//  pause-refill-resume recovery after an AirPlay auto-flush (§13/C2).

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

private final class DiscardSpySource: MixSource, @unchecked Sendable {
  let startFrame: Int64
  let envelope: FadeEnvelope
  private(set) var lastDiscardOffset: Int64?

  init(startFrame: Int64) {
    self.startFrame = startFrame
    self.envelope = FadeEnvelope(spin: Spin.mockWith(startingVolume: 1.0, fades: []))
  }

  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>? { SIMD2(0.5, 0.5) }
  func discard(beforeSourceOffset offset: Int64) { lastDiscardOffset = offset }
}

@MainActor
struct SampleBufferStationRendererTests {
  private let sampleRate: Double = 48_000
  private let framesPerBuffer = 4_096
  private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeRenderer(
    sync: FakeRenderSynchronizer, sink: FakeSampleBufferRenderer, startFrame: Int64 = 0
  ) -> SampleBufferStationRenderer {
    SampleBufferStationRenderer(
      synchronizer: sync,
      renderer: sink,
      mixer: TimelineMixer(sampleRate: sampleRate),
      mapper: TimelineMapper(anchorDate: anchor, scheduleOffset: 0, sampleRate: sampleRate),
      dateProvider: DateProviderMock(mockDate: anchor),
      startFrame: startFrame,
      sampleRate: sampleRate,
      framesPerBuffer: framesPerBuffer)
  }

  private func stub(startFrame: Int64) -> StubMixSource {
    StubMixSource(
      startFrame: startFrame,
      envelope: FadeEnvelope(spin: Spin.mockWith(startingVolume: 1.0, fades: [])),
      value: SIMD2(0.5, 0.5))
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
    // Contiguous startFrames: 0, 4096, 8192, …
    for (i, buffer) in sink.enqueued.enumerated() {
      #expect(buffer.startFrame == Int64(i * framesPerBuffer))
      #expect(buffer.frameCount == framesPerBuffer)
    }
    // Shallow queue: capped ~1s ahead of the playhead (48000 frames).
    #expect(sink.enqueued.last!.startFrame < 48_000)
    #expect(CMTimeGetSeconds(sink.enqueued[0].presentationTimeStamp) == 0)
  }

  @Test("a crossed boundary reports the spin start once")
  func boundaryReportsSpinStart() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    let spin = Spin.mockWith(id: "spin-A")
    var started: [String] = []
    renderer.onSpinStarted = { started.append($0.id) }
    renderer.setSchedule([.init(spin: spin, source: stub(startFrame: 0))])
    renderer.start()

    sync.fireBoundary()
    sync.fireBoundary()  // idempotent: once per spin

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

    renderer.supersede()  // a newer play() took over
    sync.fireBoundary()

    #expect(started.isEmpty)
  }

  @Test("fill trims each source behind the playhead to bound memory")
  func fillDiscardsBehindPlayhead() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    let spy = DiscardSpySource(startFrame: 0)
    renderer.setSchedule([.init(spin: Spin.mockWith(), source: spy)])
    // Playhead already at 1s: everything before frame 48000 is presented and safe to release.
    sync.currentTime = CMTime(seconds: 1, preferredTimescale: Int32(sampleRate))
    renderer.start()
    sink.pump()

    #expect(spy.lastDiscardOffset == 48_000)  // playhead(48000) - startFrame(0)
  }

  @Test("recovery flushes, rejoins at the current playhead, and resumes")
  func recoveryPauseRefillResume() {
    let sync = FakeRenderSynchronizer()
    let sink = FakeSampleBufferRenderer()
    let renderer = makeRenderer(sync: sync, sink: sink)
    renderer.setSchedule([.init(spin: Spin.mockWith(), source: stub(startFrame: 0))])
    renderer.start()
    sink.pump()  // initial fill from frame 0

    // Route change: the timebase has advanced to 2s; recover.
    sync.currentTime = CMTime(seconds: 2, preferredTimescale: Int32(sampleRate))
    let flushesBefore = sink.flushCount
    renderer.recoverAfterAutoFlush()

    #expect(sink.flushCount == flushesBefore + 1)
    // Rejoined at the playhead (no backfill): a buffer authored at frame 96000 exists.
    #expect(sink.enqueued.contains { $0.startFrame == 96_000 })
    // Resumed by re-anchoring the synchronizer at the playhead.
    let resume = sync.setRateCalls.last
    #expect(resume?.rate == 1.0)
    #expect(resume.map { CMTimeGetSeconds($0.time) } == 2.0)
  }
}
