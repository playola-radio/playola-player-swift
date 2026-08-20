import CoreMedia
import Foundation
import PlayolaCore
import os

/// Owns the live sample-buffer playback for one `play()` generation: builds the media stack
/// (`LiveSampleBufferSink` + `SampleBufferStationRenderer`), downloads each spin, decodes it on a
/// dedicated queue into `SpinBufferSource`s, and publishes immutable snapshots to the renderer.
///
/// This is the `.sampleBuffer` counterpart to the legacy `SpinPlayer` scheduling inside
/// `PlayolaStationPlayer`. The wall-clock schedule fetching / polling / generation stays in the station
/// player; this controller is handed the current + upcoming spins and drives the render sink.
///
/// **Threading (Codex design 019feda9):** the controller is `@MainActor` (it's created and driven from
/// the station player). Decode state (`SpinBufferSource`s) lives in `DecodePump`, confined to its own
/// serial queue; it never touches the main actor and publishes only `Sendable` `SpinPCMWindow`
/// snapshots back to the renderer, which installs them on its own request queue. Nothing shares mutable
/// audio buffers across threads.
///
/// **Device-verified, not unit-tested:** this glue needs real downloads + audio hardware; its pieces
/// (mixer, decode, renderer, snapshot) are unit-tested individually.
@MainActor
final class SampleBufferPlaybackController {
  private let fileDownloadManager: FileDownloadManaging
  private let errorReporter: PlayolaErrorReporter
  private let sampleRate: Double
  /// The timebase's deliberate head start (see `init` outputLatency): the synchronizer timeline runs
  /// this many frames AHEAD of the acoustic (speaker) timeline. Any wall-clock ↔ playhead pinning must
  /// subtract it, or every re-anchored spin presents `outputLatency` late (~2s on AirPlay).
  private let latencyFrames: Int64
  /// Re-anchored at each spin boundary from the live playhead (eng-review A1) so poll-discovered future
  /// spins are authored against fresh wall clock; main-actor confined (only `ingest`/`reanchor` touch it).
  private var mapper: TimelineMapper
  private let sink: LiveSampleBufferSink
  private let renderer: SampleBufferStationRenderer
  private let pump: DecodePump

  private var knownSpinIDs: Set<String> = []
  /// Ingested spins by id, so ended ones can be pruned (freeing their decode buffers + boundary observers).
  private var activeSpins: [String: Spin] = [:]
  private var downloadTasks: [String: Task<Void, Never>] = [:]
  private var scheduleInstalled = false
  private var rendererStarted = false

  /// Called (on the main actor) when a spin boundary is crossed — maps to `State.playing(spin)`.
  var onSpinStarted: ((Spin) -> Void)?
  /// Called (on the main actor) when playback actually begins — the first decode landed (or the startup
  /// deadline elapsed). The owner flips state to `.playing` here rather than at `start(with:)`, so a slow
  /// first download shows `.loading`, not silent `.playing` (§4.4).
  var onPlaybackStarted: (() -> Void)?

  /// - Parameters:
  ///   - anchorDate: output frame 0 on the station timeline (normally `now`). Incoming spins already
  ///     carry offset-adjusted airtimes (`Schedule.current(offsetTimeInterval:)` shifted them for
  ///     time-shifted playback), so the mapper adds NO further offset — anchoring at `now` with offset 0.
  ///   - outputLatency: measured acoustic output latency of THIS device's current route (host-fed; the
  ///     SDK can't read `AVAudioSession`). We start the timebase + write cursor this far ahead so the
  ///     audio for wall-clock T reaches the speaker AT T. With every device compensating its own route
  ///     latency (local ~18 ms, AirPlay ~2 s), all devices emit the same content at the same wall
  ///     instant → simultaneous multi-device playback (PHASE_5_PLAN §4.1). Route-change re-comp is FU-2.
  init(
    anchorDate: Date,
    fileDownloadManager: FileDownloadManaging,
    errorReporter: PlayolaErrorReporter = .shared,
    sampleRate: Double = MixFormat.sampleRate,
    outputLatency: TimeInterval = 0
  ) {
    self.fileDownloadManager = fileDownloadManager
    self.errorReporter = errorReporter
    self.sampleRate = sampleRate
    self.mapper = TimelineMapper(
      anchorDate: anchorDate, scheduleOffset: 0, sampleRate: sampleRate)

    let latencyFrames = Int64((max(0, outputLatency) * sampleRate).rounded())
    self.latencyFrames = latencyFrames
    sampleBufferLog.info(
      "controller init: outputLatency=\(outputLatency)s -> startFrame=\(latencyFrames)")
    let sink = LiveSampleBufferSink()
    self.sink = sink
    let renderer = SampleBufferStationRenderer(
      synchronizer: LiveRenderSynchronizer(sink.synchronizer),
      renderer: LiveSampleBufferRenderer(sink.renderer),
      mixer: TimelineMixer(sampleRate: sampleRate),
      startFrame: latencyFrames,
      sampleRate: sampleRate)
    self.renderer = renderer
    self.pump = DecodePump(publish: { [weak renderer] window in renderer?.updateSnapshot(window) })

    renderer.onSpinStarted = { [weak self] spin in
      Task { @MainActor in
        self?.reanchor()  // A1: re-pin the mapping to the live playhead at each boundary
        self?.pruneEndedSpins()  // free finished sources so a long session doesn't leak/degrade
        sampleBufferLog.info("boundary: spin \(spin.id, privacy: .public) started")
        self?.onSpinStarted?(spin)
      }
    }
    renderer.onLateSpinIgnored = { [weak self] spin in
      // Fires on the renderer's control queue; hop to the main actor (like onSpinStarted).
      Task { @MainActor in self?.reportLateSpin(spin) }
    }
    renderer.decodeAhead = { [weak pump] through in
      pump?.driveDecode(throughOutputFrame: through)
    }
    sink.onAutoFlush = { [weak renderer] in
      renderer?.recoverAfterAutoFlush()
    }
    pump.onFirstData = { [weak self] in
      Task { @MainActor in self?.startRendererIfNeeded() }
    }
  }

  /// Startup deadline: begin playback even if the first decode hasn't landed, so a slow/missing download
  /// can't hang the station (§4.4). Device-tunable.
  private static let startupDeadline: UInt64 = 2_000_000_000  // 2s

  /// Install the schedule + kick downloads, but DON'T start the renderer yet — start it when the first
  /// decode lands (`pump.onFirstData`) or the startup deadline elapses, to avoid enqueuing a silent
  /// startup hole into the shallow queue before any audio is decoded.
  func start(with spins: [Spin]) {
    let scheduled = spins.compactMap { ingest($0) }
    sampleBufferLog.info(
      "controller.start: \(scheduled.count)/\(spins.count) spins scheduled; waiting for first decode"
    )
    renderer.setSchedule(scheduled)
    scheduleInstalled = true
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.startupDeadline)
      if self?.rendererStarted == false {
        sampleBufferLog.notice("controller: startup deadline hit before any decode landed")
      }
      self?.startRendererIfNeeded()
    }
  }

  private func startRendererIfNeeded() {
    guard !rendererStarted else { return }
    rendererStarted = true
    sampleBufferLog.notice("controller: starting renderer (first audio ready or deadline)")
    renderer.start()
    onPlaybackStarted?()
  }

  /// Fold in later-discovered upcoming spins (from the station player's 20s poll). Cheap append for
  /// anything beyond the enqueue horizon; the renderer ignores/reports one that lands too late.
  func addUpcoming(_ spins: [Spin]) {
    let scheduled = spins.compactMap { ingest($0) }
    guard !scheduled.isEmpty else { return }
    if scheduleInstalled {
      renderer.appendScheduled(scheduled)
    } else {
      renderer.setSchedule(scheduled)
      scheduleInstalled = true
    }
  }

  func stop() {
    renderer.halt()  // freeze audio immediately, before any re-play starts a fresh sink
    for task in downloadTasks.values { task.cancel() }
    downloadTasks.removeAll()
    knownSpinIDs.removeAll()
    renderer.stop()
    pump.cancelAll()
  }

  // MARK: - Private

  /// Register a spin: compute its timeline placement, hand the renderer a silent placeholder snapshot
  /// (so the boundary observer installs now), and kick off download → decode → real snapshot. Returns
  /// the placeholder `Scheduled`, or nil if already known / no URL.
  private func ingest(_ spin: Spin) -> SampleBufferStationRenderer.Scheduled? {
    guard !knownSpinIDs.contains(spin.id), let remoteUrl = spin.audioBlock.downloadUrl else {
      return nil
    }
    knownSpinIDs.insert(spin.id)
    activeSpins[spin.id] = spin

    let startFrame = mapper.frame(for: spin.airtime)
    let initialOffset = max(0, -startFrame)  // mid-file join for an already-airing spin
    let envelope = FadeEnvelope(spin: spin)
    let placeholder = SpinPCMWindow(
      spinID: spin.id, startFrame: startFrame, envelope: envelope,
      windowStart: initialOffset, frames: [])

    downloadTasks[spin.id] = Task { [weak self] in
      await self?.download(
        spin: spin, remoteUrl: remoteUrl, startFrame: startFrame, offset: initialOffset)
    }

    return SampleBufferStationRenderer.Scheduled(spin: spin, source: placeholder)
  }

  private func download(spin: Spin, remoteUrl: URL, startFrame: Int64, offset: Int64) async {
    do {
      let localUrl = try await fileDownloadManager.downloadFileAsync(
        remoteUrl: remoteUrl, progressHandler: nil)
      if Task.isCancelled { return }
      pump.prepare(spin: spin, fileURL: localUrl, startFrame: startFrame, initialOffset: offset)
    } catch {
      if !(error is CancellationError) {
        await errorReporter.reportError(
          error, context: "Sample-buffer download failed for spin \(spin.id)", level: .error)
      }
    }
  }

  /// Re-anchor the wall-clock → frame mapping to the synchronizer's current playhead so spins scheduled
  /// after this boundary track fresh wall clock (bounds long-session drift; A1). Main-actor confined.
  private func reanchor() {
    let seconds = CMTimeGetSeconds(sink.synchronizer.currentTime())
    guard seconds.isFinite else { return }
    // currentTime() is the renderer timeline, which starts `latencyFrames` ahead of the acoustic
    // timeline (init's outputLatency head start). Pin wall clock to the ACOUSTIC playhead, or every
    // spin mapped after this boundary presents `outputLatency` late (~2s on AirPlay).
    let playhead = Int64((seconds * sampleRate).rounded()) - latencyFrames
    mapper = mapper.reanchored(now: Date(), currentStationFrame: playhead)
  }

  /// Drop spins whose airtime window ended comfortably in the past (past playback + the ~2s AirPlay
  /// presentation lag + the enqueue lead), freeing their decode buffers, render snapshot, and boundary
  /// observer. Without this, every spin ever played is retained for the whole session (memory grows and
  /// the decode pass degrades — each spin starts to cut to silence after its eager initial decode).
  private func pruneEndedSpins() {
    let cutoff = Date().addingTimeInterval(-8)  // generous grace past playback/AirPlay latency
    let ended = Set(activeSpins.filter { $0.value.endtime < cutoff }.keys)
    guard !ended.isEmpty else { return }
    for id in ended { activeSpins[id] = nil }
    renderer.removeSpins(ended)
    pump.removeSources(ended)
    sampleBufferLog.info("pruned \(ended.count) ended spins (active=\(self.activeSpins.count))")
  }

  private func reportLateSpin(_ spin: Spin) {
    Task {
      await errorReporter.reportError(
        StationPlayerError.playbackError(
          "Sample-buffer schedule change landed inside the enqueue horizon; ignored (spin \(spin.id))"
        ),
        level: .warning)
    }
  }
}

/// Owns the decode-side `SpinBufferSource`s, confined to a single serial queue. Publishes immutable
/// `SpinPCMWindow` snapshots to the renderer; never touches the main actor or shares mutable buffers.
private final class DecodePump: @unchecked Sendable {
  private let queue = DispatchQueue(label: "fm.playola.samplebuffer.decode", qos: .userInitiated)
  private var sources: [String: SpinBufferSource] = [:]  // queue-confined
  private var firstDataSignaled = false  // queue-confined
  private let publish: @Sendable (SpinPCMWindow) -> Void
  /// Coalesce decode requests: fill signals every ~85ms, but only ONE decode pass need be queued at a
  /// time (it always decodes to the latest target). Without this the decode queue backs up and the only
  /// current PCM is the eager initial 2s — each spin then plays ~2s and cuts to silence.
  private let decodeRequest = OSAllocatedUnfairLock<(scheduled: Bool, target: Int64)>(
    initialState: (false, 0))

  /// Fired once, after the first source decodes some PCM — the controller uses it to start the renderer
  /// (avoids a silent startup hole). Set before any decode begins.
  var onFirstData: (@Sendable () -> Void)?

  init(publish: @escaping @Sendable (SpinPCMWindow) -> Void) {
    self.publish = publish
  }

  func prepare(spin: Spin, fileURL: URL, startFrame: Int64, initialOffset: Int64) {
    queue.async { [self] in
      do {
        let source = try SpinBufferSource(
          spin: spin, fileURL: fileURL, startFrame: startFrame, initialSourceOffset: initialOffset)
        try source.decode(
          throughSourceOffset: initialOffset + Int64(SpinBufferSource.readAheadFrames))
        sources[spin.id] = source
        publish(source.snapshot())
        if !firstDataSignaled {
          firstDataSignaled = true
          onFirstData?()
        }
      } catch {
        // A failed decode contributes silence (the mixer renders nil frames); the station continues.
      }
    }
  }

  func driveDecode(throughOutputFrame through: Int64) {
    let shouldDispatch = decodeRequest.withLock { req -> Bool in
      req.target = max(req.target, through)
      if req.scheduled { return false }
      req.scheduled = true
      return true
    }
    guard shouldDispatch else { return }
    queue.async { [self] in
      let through = decodeRequest.withLock { req -> Int64 in
        req.scheduled = false
        return req.target
      }
      for (_, source) in sources {
        let target = through - source.startFrame
        guard target > source.decodedThroughOffset, !source.isFullyDecoded else { continue }
        do {
          try source.decode(throughSourceOffset: target)
        } catch {
          continue
        }
        // Bound memory: drop already-presented audio well behind the decode target.
        let keepBehind = Int64(SpinBufferSource.readAheadFrames) * 2
        source.discard(beforeSourceOffset: max(0, target - keepBehind))
        publish(source.snapshot())
      }
    }
  }

  /// Free the decode buffers for ended spins (they'd otherwise leak ~1.5MB each for the whole session).
  func removeSources(_ ids: Set<String>) {
    queue.async { [self] in for id in ids { sources[id] = nil } }
  }

  func cancelAll() {
    queue.async { [self] in sources.removeAll() }
  }
}
