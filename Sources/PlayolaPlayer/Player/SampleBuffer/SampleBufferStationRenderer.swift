import CoreMedia
import Foundation
import PlayolaCore
import os

/// Serializes all sample-buffer render + control work onto one domain. Production uses the renderer's
/// request queue (the same serial queue `requestMediaDataWhenReady` runs the fill block on), so control
/// mutations and the render pull never race. Unit tests inject `ImmediateControlExecutor` to run
/// synchronously (Codex design 019feda9).
protocol RenderControlExecutor: Sendable {
  func execute(_ work: @escaping @Sendable () -> Void)
}

struct QueueControlExecutor: RenderControlExecutor {
  let queue: DispatchQueue
  func execute(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}

struct ImmediateControlExecutor: RenderControlExecutor {
  func execute(_ work: @escaping @Sendable () -> Void) { work() }
}

/// Drives the sample-buffer render path: pulls mixed program PCM from the `TimelineMixer` into the
/// `SampleBufferRendering` sink on demand, maps synchronizer boundary observers to spin-start events,
/// enforces play-generation supersession, folds in dynamically-scheduled spins, and performs the
/// device-proven pause-refill-resume recovery after an AirPlay route auto-flush (PHASE_5_PLAN §4.1/§13).
///
/// **Threading:** every field below is confined to the control executor's serial domain (== request
/// queue in production). Control methods hop onto it; `fill()` already runs there (it's the
/// `requestMediaDataWhenReady` block); boundary observers hop onto it too. The render pull reads only
/// immutable `MixSource` snapshots — decode happens on a separate queue and publishes via
/// `updateSnapshot`. `@unchecked Sendable` is justified by that single-domain confinement.
final class SampleBufferStationRenderer: @unchecked Sendable {
  struct Scheduled {
    let spin: Spin
    /// Immutable, decode/IO-free snapshot for this spin; its `startFrame` fixes the boundary time.
    var source: MixSource
  }

  private let synchronizer: RenderSynchronizing
  private let renderer: SampleBufferRendering
  private let mixer: TimelineMixer
  private let sampleRate: Double
  private let framesPerBuffer: Int
  /// Shallow enqueue horizon (≈ read-ahead window) so re-anchor / recovery is a cheap flush+refill and
  /// dynamically-added spins beyond it are a clean append, not queued-tail surgery (§4.1/C2, §8.8).
  private let maxEnqueueAheadFrames: Int64
  /// The timebase's latency-compensation head start (init `startFrame`): the synchronizer timeline runs
  /// this far AHEAD of the acoustic timeline, so anything pinned to when audio is actually HEARD
  /// (boundary observers → `.playing(spin)`) must be shifted by it.
  private let timebaseLeadFrames: Int64
  private let requestQueue: DispatchQueue
  private let control: RenderControlExecutor

  // Confined to the control domain:
  private var scheduled: [Scheduled] = []
  private var nextOutputFrame: Int64
  private var generation = 0
  private var boundaryTokens: [Any] = []
  private var startedSpinIDs: Set<String> = []
  private var stopped = false
  /// Reusable mix output buffer (sized to `framesPerBuffer`), to avoid a per-buffer allocation.
  private var frameScratch: [SIMD2<Float>] = []

  /// Fired (on the control domain) when a spin boundary is crossed. The OWNER's closure hops to the
  /// main actor and checks its own generation before publishing `State.playing(spin)`.
  var onSpinStarted: ((Spin) -> Void)?
  /// Fired when a dynamically-appended spin lands INSIDE the enqueue horizon (too late for a clean
  /// append); the owner logs/reports it. Slice 1 does not edit already-queued audio (§7 OUT).
  var onLateSpinIgnored: ((Spin) -> Void)?
  /// Non-blocking signal (on the control domain) that decode should run ahead to `throughOutputFrame`.
  /// The owner's closure must dispatch to the DECODE queue, decode, snapshot, and call `updateSnapshot`
  /// — it must NOT decode inline on the render path (A2).
  var decodeAhead: ((_ throughOutputFrame: Int64) -> Void)?

  init(
    synchronizer: RenderSynchronizing,
    renderer: SampleBufferRendering,
    mixer: TimelineMixer,
    startFrame: Int64,
    sampleRate: Double = MixFormat.sampleRate,
    framesPerBuffer: Int = 4_096,
    requestQueue: DispatchQueue = DispatchQueue(label: "fm.playola.samplebuffer.request"),
    control: RenderControlExecutor? = nil,
    enqueueAheadSeconds: Double = 3.0
  ) {
    self.synchronizer = synchronizer
    self.renderer = renderer
    self.mixer = mixer
    self.nextOutputFrame = startFrame
    self.timebaseLeadFrames = startFrame
    self.sampleRate = sampleRate
    self.framesPerBuffer = framesPerBuffer
    // Keep enough audio queued ahead to cover the AirPlay presentation pipeline (~2s) with margin, so a
    // post-route-change refill doesn't underrun (C10 — tune read-ahead vs AirPlay jitter on device).
    self.maxEnqueueAheadFrames = Int64(sampleRate * enqueueAheadSeconds)
    self.requestQueue = requestQueue
    self.control = control ?? QueueControlExecutor(queue: requestQueue)
  }

  // MARK: - Control (all hop onto the serial control domain)

  func setSchedule(_ items: [Scheduled]) {
    control.execute { [self] in
      guard !stopped else { return }
      scheduled = items
      installBoundaryObservers()
    }
  }

  /// Fold newly-discovered upcoming spins into a running renderer. Slice 1 supports only the cheap case:
  /// a spin whose start frame is beyond the enqueue horizon (append). One landing inside the horizon
  /// fires `onLateSpinIgnored` (no in-place queued-tail surgery).
  func appendScheduled(_ items: [Scheduled]) {
    control.execute { [self] in
      guard !stopped else { return }
      // Clean-append cutoff is the WRITE CURSOR: no buffer at/after `nextOutputFrame` has been enqueued
      // yet, so a spin starting there or later just needs a source + boundary observer. A spin starting
      // before it is already inside queued audio → surgery (out of scope for slice 1).
      let horizon = nextOutputFrame
      for item in items where !scheduled.contains(where: { $0.spin.id == item.spin.id }) {
        if item.source.startFrame >= horizon {
          scheduled.append(item)
          installBoundaryObserver(for: item)
        } else {
          onLateSpinIgnored?(item.spin)
        }
      }
    }
  }

  /// Drop ended spins from the mix schedule (and their boundary observers) so a long session doesn't
  /// accumulate finished sources. The owner passes spins whose airtime window is safely in the past.
  func removeSpins(_ ids: Set<String>) {
    control.execute { [self] in
      guard !stopped, !ids.isEmpty else { return }
      let before = scheduled.count
      scheduled.removeAll { ids.contains($0.spin.id) }
      startedSpinIDs.subtract(ids)
      if scheduled.count != before { installBoundaryObservers() }
    }
  }

  /// Publish a freshly-decoded PCM window from the decode queue, replacing that spin's render snapshot.
  func updateSnapshot(_ window: SpinPCMWindow) {
    control.execute { [self] in
      guard !stopped else { return }
      if let i = scheduled.firstIndex(where: { $0.spin.id == window.spinID }) {
        scheduled[i].source = window
      }
    }
  }

  /// Anchor the synchronizer at the start frame and begin pulling media.
  func start() {
    control.execute { [self] in
      guard !stopped else { return }
      sampleBufferLog.info("start: anchor timebase at frame=\(self.nextOutputFrame)")
      synchronizer.setRate(1.0, time: cmTime(nextOutputFrame))
    }
    renderer.requestMediaDataWhenReady(on: requestQueue) { [weak self] in
      self?.fill()  // runs on requestQueue == control domain
    }
  }

  /// Supersede: pending boundary/fill work tagged with an older generation is ignored.
  func supersede() {
    control.execute { [self] in generation += 1 }
  }

  /// Synchronous, immediate halt for teardown-before-replacement: stop pulling and freeze the timebase
  /// NOW, so a re-play starting a fresh sink cannot briefly overlap this one's audio. Safe to call from
  /// any thread (the underlying CoreMedia calls are); the ordered cleanup still runs via `stop()`.
  func halt() {
    halted.withLock { $0 = true }
    renderer.stopRequestingMediaData()
    synchronizer.setRate(0, time: synchronizer.currentTime)
  }

  /// Synchronously-visible halt fence: `stopped` only flips inside the queued `stop()` closure, so a
  /// recovery already queued between `halt()` and that closure could otherwise setRate(1.0) a
  /// deliberately-frozen timebase. Checked by `recoverAfterAutoFlush`.
  private let halted = OSAllocatedUnfairLock(initialState: false)

  /// Ordered teardown [Codex Q3 / spike EXC_BAD_ACCESS]: supersede, stop pulling, remove observers,
  /// flush, drop the closures that publish back to the owner — before the owner releases us.
  func stop() {
    control.execute { [self] in
      generation += 1
      stopped = true
      renderer.stopRequestingMediaData()
      removeBoundaryObservers()
      renderer.flush()
      scheduled = []
      onSpinStarted = nil
      onLateSpinIgnored = nil
      decodeAhead = nil
    }
  }

  /// Minimal recovery after `AVSampleBufferAudioRendererWasFlushedAutomatically` (route change). The
  /// renderer flushed its own queue but keeps rendering at rate 1.0 — the ONLY thing it needs from us is
  /// to re-point the write cursor to the current playhead (the flushed buffers are gone) and let the
  /// media-pull loop refill from there. We deliberately do NOT manually flush or re-issue setRate:
  /// during an unsettled route those repeat every ~0.3s and each one restarts the timebase / discards the
  /// just-refilled audio, which is the warble/stutter. Only resume the timebase if it's actually paused.
  func recoverAfterAutoFlush() {
    control.execute { [self] in
      guard !stopped, !halted.withLock({ $0 }) else { return }
      let playhead = playheadFrame()
      nextOutputFrame = playhead  // never backfill (§4.4); refill from where the timebase actually is
      fillLocked()
      if synchronizer.rate != 1.0 {
        synchronizer.setRate(1.0, time: synchronizer.currentTime)
      }
      sampleBufferLog.notice(
        "recover: re-anchored to \(playhead), refilled \(self.nextOutputFrame - playhead) ahead")
    }
  }

  // MARK: - Media pull (runs on the control domain)

  /// Entry point from `requestMediaDataWhenReady` (already on the request/control queue).
  func fill() {
    fillLocked()
  }

  /// How far decode is driven BEYOND the enqueue window, so each range is decoded and its snapshot
  /// published before the mixer reaches it (snapshot publication lags a fill; without this lead the
  /// leading edge of each fill mixes to silence — frequent little stutters).
  private var decodeLeadFrames: Int64 { Int64(sampleRate * 1.0) }

  /// How often we top up when already `maxEnqueueAheadFrames` ahead (see `fillLocked`).
  private let topUpInterval: TimeInterval = 0.2

  private func fillLocked() {
    guard !stopped else { return }
    let gen = generation

    // Drive decode once, comfortably ahead of everything we'll enqueue this pass (non-blocking; the
    // owner dispatches it to the decode queue). The mix step only reads already-ready snapshots.
    decodeAhead?(playheadFrame() + maxEnqueueAheadFrames + decodeLeadFrames)

    // Compute the source snapshots once per pass (not per buffer), and keep a reusable frame buffer.
    let currentSources = scheduled.map { $0.source }
    if frameScratch.count != framesPerBuffer {
      frameScratch = [SIMD2<Float>](repeating: .zero, count: framesPerBuffer)
    }

    var cappedWhileReady = false
    while renderer.isReadyForMoreMediaData {
      // Never backfill (§4.4): if the playhead ran past the write cursor (delayed callback / route
      // change), rejoin at the playhead rather than enqueue buffers whose PTS is already in the past.
      let playhead = playheadFrame()
      if nextOutputFrame < playhead { nextOutputFrame = playhead }
      if nextOutputFrame - playhead >= maxEnqueueAheadFrames {
        cappedWhileReady = true
        break
      }
      guard gen == generation else { return }
      let range = nextOutputFrame..<(nextOutputFrame + Int64(framesPerBuffer))

      // Reuse one frame buffer across the pass and mix straight into it (no per-buffer scratch alloc,
      // zeroing, or float→SIMD2 conversion). The live sink copies it into a CMBlockBuffer synchronously,
      // so it's free to overwrite next iteration; the fake test sink retains it (COW keeps them distinct).
      mixer.render(outputFrameRange: range, sources: currentSources, intoFrames: &frameScratch)
      renderer.enqueue(
        RenderBuffer(startFrame: range.lowerBound, sampleRate: sampleRate, frames: frameScratch))
      nextOutputFrame = range.upperBound
    }

    // Energy: if we stopped because WE'RE far enough ahead (not because the renderer is full), do NOT
    // just return — the renderer is still `isReadyForMoreMediaData` and would busy-call this block
    // continuously (a spinning core, esp. on AirPlay whose appetite exceeds our shallow queue). Instead
    // stop being polled and top up again shortly.
    if cappedWhileReady {
      renderer.stopRequestingMediaData()
      requestQueue.asyncAfter(deadline: .now() + topUpInterval) { [weak self] in
        guard let self, !self.stopped else { return }
        self.renderer.requestMediaDataWhenReady(on: self.requestQueue) { [weak self] in self?.fill()
        }
      }
    }
  }

  // MARK: - Private

  private func cmTime(_ frame: Int64) -> CMTime {
    CMTime(value: frame, timescale: Int32(sampleRate))
  }

  private func playheadFrame() -> Int64 {
    Int64((CMTimeGetSeconds(synchronizer.currentTime) * sampleRate).rounded())
  }

  private func installBoundaryObservers() {
    removeBoundaryObservers()
    for item in scheduled { installBoundaryObserver(for: item) }
  }

  private func installBoundaryObserver(for item: Scheduled) {
    // Fire when the spin is HEARD, not when its frames are presented to the route: the timebase leads
    // the speaker by `timebaseLeadFrames` (latency compensation), so observe on the renderer timeline.
    let time = cmTime(item.source.startFrame + timebaseLeadFrames)
    let spin = item.spin
    let gen = generation
    let token = synchronizer.addBoundaryObserver(forTimes: [time]) { [weak self] in
      guard let self else { return }
      // Hop onto the control domain: the observer may fire on the synchronizer's queue.
      self.control.execute { self.handleBoundary(spin: spin, generation: gen) }
    }
    boundaryTokens.append(token)
  }

  private func removeBoundaryObservers() {
    for token in boundaryTokens { synchronizer.removeObserver(token) }
    boundaryTokens.removeAll()
  }

  private func handleBoundary(spin: Spin, generation gen: Int) {
    guard !stopped, gen == generation else { return }  // superseded / torn down — never publish
    guard startedSpinIDs.insert(spin.id).inserted else { return }  // once per spin
    onSpinStarted?(spin)
  }
}
