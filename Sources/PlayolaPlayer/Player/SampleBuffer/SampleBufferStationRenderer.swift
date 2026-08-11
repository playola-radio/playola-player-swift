import CoreMedia
import Foundation
import PlayolaCore

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
  private let requestQueue: DispatchQueue
  private let control: RenderControlExecutor

  // Confined to the control domain:
  private var scheduled: [Scheduled] = []
  private var nextOutputFrame: Int64
  private var generation = 0
  private var boundaryTokens: [Any] = []
  private var startedSpinIDs: Set<String> = []
  private var stopped = false
  /// Coalesce the burst of auto-flushes a route change posts into ONE recovery once it goes quiet.
  private let recoveryDebounce: TimeInterval
  private var recoveryGeneration = 0

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
    recoveryDebounce: TimeInterval = 0.35
  ) {
    self.synchronizer = synchronizer
    self.renderer = renderer
    self.mixer = mixer
    self.nextOutputFrame = startFrame
    self.sampleRate = sampleRate
    self.framesPerBuffer = framesPerBuffer
    self.maxEnqueueAheadFrames = Int64(sampleRate * 1.0)
    self.requestQueue = requestQueue
    self.control = control ?? QueueControlExecutor(queue: requestQueue)
    self.recoveryDebounce = recoveryDebounce
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
    renderer.stopRequestingMediaData()
    synchronizer.setRate(0, time: synchronizer.currentTime)
  }

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

  /// Pause-refill-resume recovery after `AVSampleBufferAudioRendererWasFlushedAutomatically` (route
  /// change). At real AirPlay latency the "keep-running, re-enqueue-from-now" option lands audio in the
  /// past → silence; Apple's pause option is what works (§13). Never backfill: rejoin at the playhead.
  func recoverAfterAutoFlush() {
    control.execute { [self] in
      guard !stopped else {
        sampleBufferLog.notice("recover: ignored (already stopped)")
        return
      }
      recoveryGeneration += 1
      let gen = recoveryGeneration
      guard recoveryDebounce > 0 else {
        performRecovery()
        return
      }
      // A route change posts a BURST of auto-flushes as it settles. Reacting to each with
      // flush+refill+setRate starves the AirPlay pipeline so it never plays. Coalesce: recover once,
      // after `recoveryDebounce` of quiet. Each new auto-flush bumps `gen` and cancels the earlier wait.
      sampleBufferLog.notice(
        "recover: debounced (#\(gen)); waiting \(self.recoveryDebounce)s for quiet")
      requestQueue.asyncAfter(deadline: .now() + recoveryDebounce) { [weak self] in
        guard let self, !self.stopped, self.recoveryGeneration == gen else { return }
        self.performRecovery()
      }
    }
  }

  /// The actual pause-refill-resume, run once per settled route change (on the control domain).
  private func performRecovery() {
    let playhead = playheadFrame()
    sampleBufferLog.notice(
      "recover: begin playhead=\(playhead) ready=\(self.renderer.isReadyForMoreMediaData)")
    renderer.flush()
    startedSpinIDs.removeAll()
    nextOutputFrame = playhead
    fillLocked()
    synchronizer.setRate(1.0, time: cmTime(playhead))
    let enqueuedAhead = nextOutputFrame - playhead
    sampleBufferLog.notice(
      "recover: resumed rate=1.0 at \(playhead); refilled \(enqueuedAhead) frames ahead (\(enqueuedAhead == 0 ? "NOTHING ENQUEUED — will be silent" : "ok"))"
    )
  }

  // MARK: - Media pull (runs on the control domain)

  /// Entry point from `requestMediaDataWhenReady` (already on the request/control queue).
  func fill() {
    fillLocked()
  }

  private func fillLocked() {
    guard !stopped else { return }
    let gen = generation
    while renderer.isReadyForMoreMediaData {
      // Never backfill (§4.4): if the playhead ran past the write cursor (delayed callback / route
      // change), rejoin at the playhead rather than enqueue buffers whose PTS is already in the past.
      let playhead = playheadFrame()
      if nextOutputFrame < playhead { nextOutputFrame = playhead }
      guard nextOutputFrame - playhead < maxEnqueueAheadFrames else { break }
      let range = nextOutputFrame..<(nextOutputFrame + Int64(framesPerBuffer))

      // Signal decode to run ahead (non-blocking); the mix step below only reads ready snapshots.
      decodeAhead?(range.upperBound + Int64(framesPerBuffer))
      guard gen == generation else { return }

      var scratch = [Float](repeating: 0, count: framesPerBuffer * 2)
      mixer.render(outputFrameRange: range, sources: scheduled.map { $0.source }, into: &scratch)

      var frames = [SIMD2<Float>]()
      frames.reserveCapacity(framesPerBuffer)
      for i in 0..<framesPerBuffer {
        frames.append(SIMD2(scratch[i * 2], scratch[i * 2 + 1]))
      }
      renderer.enqueue(
        RenderBuffer(startFrame: range.lowerBound, sampleRate: sampleRate, frames: frames))
      nextOutputFrame = range.upperBound
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
    let time = cmTime(item.source.startFrame)
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
