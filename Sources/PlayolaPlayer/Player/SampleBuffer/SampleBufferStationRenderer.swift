import CoreMedia
import Foundation
import PlayolaCore

/// Drives the sample-buffer render path: pulls mixed program PCM from the `TimelineMixer` into the
/// `SampleBufferRendering` sink on demand, maps synchronizer boundary observers to spin-start events,
/// enforces play-generation supersession, and performs the device-proven pause-refill-resume recovery
/// after an AirPlay route auto-flush (PHASE_5_PLAN §4.1 / §13 / C2).
///
/// Threading contract (slice 1): control calls (`setSchedule`, `start`, `supersede`, `stop`,
/// `recoverAfterAutoFlush`) and the `fill()` pull run serialized on the owner's executor; boundary
/// observers arrive on the synchronizer's queue and only read immutable schedule state + hop spin-start
/// out through `onSpinStarted`. Full lock-free render-thread hardening (C11) and teardown ordering (C13)
/// are the device-verified follow-up. `@unchecked Sendable`: it holds non-Sendable CoreMedia-adjacent
/// deps that the owner serializes.
final class SampleBufferStationRenderer: @unchecked Sendable {
  struct Scheduled {
    let spin: Spin
    /// Decode/IO-free mix source for this spin; its `startFrame` fixes the boundary time.
    let source: MixSource
  }

  private let synchronizer: RenderSynchronizing
  private let renderer: SampleBufferRendering
  private let mixer: TimelineMixer
  private let dateProvider: DateProviderProtocol
  private let sampleRate: Double
  private let framesPerBuffer: Int
  /// Keep the enqueue queue shallow (≈ read-ahead window) so a boundary re-anchor / recovery is a cheap
  /// tail flush + refill (PHASE_5_PLAN §4.1/C2, §8.8 memory bound).
  private let maxEnqueueAheadFrames: Int64
  private let requestQueue: DispatchQueue

  private var mapper: TimelineMapper
  private var scheduled: [Scheduled] = []
  private var nextOutputFrame: Int64
  private var generation = 0
  private var boundaryTokens: [Any] = []
  private var startedSpinIDs: Set<String> = []

  /// Fired when a spin's boundary is crossed (maps to `PlayolaStationPlayer.State.playing(spin)`).
  var onSpinStarted: ((Spin) -> Void)?
  /// Drives real `SpinBufferSource` pre-decode ahead of the render position; nil in pure tests.
  var decodeAhead: ((_ throughOutputFrame: Int64) -> Void)?

  init(
    synchronizer: RenderSynchronizing,
    renderer: SampleBufferRendering,
    mixer: TimelineMixer,
    mapper: TimelineMapper,
    dateProvider: DateProviderProtocol,
    startFrame: Int64,
    sampleRate: Double = MixFormat.sampleRate,
    framesPerBuffer: Int = 4_096,
    requestQueue: DispatchQueue = DispatchQueue(label: "fm.playola.samplebuffer.request")
  ) {
    self.synchronizer = synchronizer
    self.renderer = renderer
    self.mixer = mixer
    self.mapper = mapper
    self.dateProvider = dateProvider
    self.nextOutputFrame = startFrame
    self.sampleRate = sampleRate
    self.framesPerBuffer = framesPerBuffer
    self.maxEnqueueAheadFrames = Int64(sampleRate * 1.0)
    self.requestQueue = requestQueue
  }

  // MARK: - Control

  func setSchedule(_ items: [Scheduled]) {
    scheduled = items
    installBoundaryObservers()
  }

  /// Anchor the synchronizer at the start frame and begin pulling media.
  func start() {
    synchronizer.setRate(1.0, time: CMTime(value: nextOutputFrame, timescale: Int32(sampleRate)))
    renderer.requestMediaDataWhenReady(on: requestQueue) { [weak self] in
      self?.fill()
    }
  }

  /// Supersede: any pending boundary/fill work tagged with an older generation is ignored.
  func supersede() {
    generation += 1
  }

  func stop() {
    supersede()
    renderer.stopRequestingMediaData()
    renderer.flush()
    removeBoundaryObservers()
  }

  /// Pause-refill-resume recovery after `AVSampleBufferAudioRendererWasFlushedAutomatically` (route
  /// change). At real AirPlay latency the "keep-running, re-enqueue-from-now" option lands audio in the
  /// past → silence; Apple's pause option is what works (PHASE_5_PLAN §13). Never backfill: rejoin at the
  /// current playhead (§4.4).
  func recoverAfterAutoFlush() {
    let playhead = playheadFrame()
    renderer.flush()
    startedSpinIDs.removeAll()
    nextOutputFrame = playhead
    mapper = mapper.reanchored(now: dateProvider.now(), currentStationFrame: playhead)
    fill()
    synchronizer.setRate(1.0, time: CMTime(value: playhead, timescale: Int32(sampleRate)))
  }

  // MARK: - Media pull

  /// Pull mixed PCM into the sink while it wants data, keeping the queue shallow. Decode/IO-free in the
  /// mix step itself: `decodeAhead` (pre-decode) runs first, then the mixer only sums ready PCM (A2/T9).
  func fill() {
    let gen = generation
    while renderer.isReadyForMoreMediaData {
      guard nextOutputFrame - playheadFrame() < maxEnqueueAheadFrames else { break }
      let range = nextOutputFrame..<(nextOutputFrame + Int64(framesPerBuffer))

      decodeAhead?(range.upperBound + Int64(framesPerBuffer))
      guard gen == generation else { return }  // superseded during pre-decode

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

    // Release already-presented audio behind the playhead to bound memory (P1). Never drops frames the
    // mixer may still read (the playhead trails the enqueue position).
    let playhead = playheadFrame()
    for item in scheduled {
      item.source.discard(beforeSourceOffset: playhead - item.source.startFrame)
    }
  }

  // MARK: - Private

  private func playheadFrame() -> Int64 {
    Int64((CMTimeGetSeconds(synchronizer.currentTime) * sampleRate).rounded())
  }

  private func installBoundaryObservers() {
    removeBoundaryObservers()
    for item in scheduled {
      let time = CMTime(value: item.source.startFrame, timescale: Int32(sampleRate))
      let spin = item.spin
      let gen = generation
      let token = synchronizer.addBoundaryObserver(forTimes: [time]) { [weak self] in
        self?.handleBoundary(spin: spin, generation: gen)
      }
      boundaryTokens.append(token)
    }
  }

  private func removeBoundaryObservers() {
    for token in boundaryTokens { synchronizer.removeObserver(token) }
    boundaryTokens.removeAll()
  }

  /// The current wall-clock → frame mapping, re-anchored at each boundary. The owner reads this when
  /// scheduling the NEXT window of spins so their authored frames track fresh wall clock (A1). It does
  /// not move already-authored frames or already-installed boundary observers — corrections land at the
  /// next cut point, by design (§4.1).
  var currentMapper: TimelineMapper { mapper }

  private func handleBoundary(spin: Spin, generation gen: Int) {
    guard gen == generation else { return }  // superseded session — never publish
    guard startedSpinIDs.insert(spin.id).inserted else { return }  // once per spin
    // Boundary re-anchor from fresh wall clock (A1): updates the mapping used to schedule FUTURE spins;
    // already-authored frames/observers are unchanged.
    mapper = mapper.reanchored(now: dateProvider.now(), currentStationFrame: playheadFrame())
    onSpinStarted?(spin)
  }
}
