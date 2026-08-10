import CoreMedia
import Foundation
import PlayolaCore

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
  /// Re-anchored at each spin boundary from the live playhead (eng-review A1) so poll-discovered future
  /// spins are authored against fresh wall clock; main-actor confined (only `ingest`/`reanchor` touch it).
  private var mapper: TimelineMapper
  private let sink: LiveSampleBufferSink
  private let renderer: SampleBufferStationRenderer
  private let pump: DecodePump

  private var knownSpinIDs: Set<String> = []
  private var downloadTasks: [String: Task<Void, Never>] = [:]
  private var started = false

  /// Called (on the main actor) when a spin boundary is crossed — maps to `State.playing(spin)`.
  var onSpinStarted: ((Spin) -> Void)?

  /// - Parameter anchorDate: output frame 0 on the station timeline (normally `now`). Incoming spins
  ///   already carry offset-adjusted airtimes (`Schedule.current(offsetTimeInterval:)` shifted them for
  ///   time-shifted playback), so the mapper adds NO further offset — anchoring at `now` with offset 0.
  init(
    anchorDate: Date,
    fileDownloadManager: FileDownloadManaging,
    errorReporter: PlayolaErrorReporter = .shared,
    sampleRate: Double = MixFormat.sampleRate
  ) {
    self.fileDownloadManager = fileDownloadManager
    self.errorReporter = errorReporter
    self.sampleRate = sampleRate
    self.mapper = TimelineMapper(
      anchorDate: anchorDate, scheduleOffset: 0, sampleRate: sampleRate)

    let sink = LiveSampleBufferSink()
    self.sink = sink
    let renderer = SampleBufferStationRenderer(
      synchronizer: LiveRenderSynchronizer(sink.synchronizer),
      renderer: LiveSampleBufferRenderer(sink.renderer),
      mixer: TimelineMixer(sampleRate: sampleRate),
      startFrame: 0,
      sampleRate: sampleRate)
    self.renderer = renderer
    self.pump = DecodePump(publish: { [weak renderer] window in renderer?.updateSnapshot(window) })

    renderer.onSpinStarted = { [weak self] spin in
      Task { @MainActor in
        self?.reanchor()  // A1: re-pin the mapping to the live playhead at each boundary
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
  }

  /// Begin playback with the currently-airing + immediately-upcoming spins.
  func start(with spins: [Spin]) {
    let scheduled = spins.compactMap { ingest($0) }
    renderer.setSchedule(scheduled)
    renderer.start()
    started = true
  }

  /// Fold in later-discovered upcoming spins (from the station player's 20s poll). Cheap append for
  /// anything beyond the enqueue horizon; the renderer ignores/reports one that lands too late.
  func addUpcoming(_ spins: [Spin]) {
    let scheduled = spins.compactMap { ingest($0) }
    guard !scheduled.isEmpty else { return }
    if started {
      renderer.appendScheduled(scheduled)
    } else {
      renderer.setSchedule(scheduled)
    }
  }

  func stop() {
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
    let playhead = Int64((seconds * sampleRate).rounded())
    mapper = mapper.reanchored(now: Date(), currentStationFrame: playhead)
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
  private let publish: @Sendable (SpinPCMWindow) -> Void

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
      } catch {
        // A failed decode contributes silence (the mixer renders nil frames); the station continues.
      }
    }
  }

  func driveDecode(throughOutputFrame through: Int64) {
    queue.async { [self] in
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

  func cancelAll() {
    queue.async { [self] in sources.removeAll() }
  }
}
