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
  /// Downloaded local file path per spin, so the owner can exclude in-use files from cache pruning.
  private var localFilePaths: [String: String] = [:]
  private var scheduleInstalled = false
  private var rendererStarted = false
  /// Whether playback has been published to the owner — either `onPlaybackStarted` fired, or a spin
  /// boundary crossing (`onSpinStarted`) already published `.playing` for a spin OTHER than the
  /// still-unresolved airing spin (see `handleSpinStarted`; the airing spin's own boundary crossing does
  /// not count — it can fire before its decode lands). Distinct from `rendererStarted`: the startup
  /// deadline can start the renderer with no decode landed yet, and the state machine must stay `.loading`
  /// (not silently `.playing`) until playback is actually imminent — see `onPlaybackStarted`'s doc
  /// comment. Also gates `onLoadProgress`: once true, the airing spin's download progress must never fire
  /// again, whether it was superseded by its own audible decode/failure or by a later spin's boundary
  /// crossing.
  private var playbackPublished = false
  /// Set when the airing spin's download/decode fails, so that whenever the renderer eventually starts
  /// (now, or later at the deadline) playback publishes immediately instead of waiting forever for a
  /// decode that will never land.
  private var airingSpinFailed = false
  /// Set the first time ANY decode lands for the airing spin, regardless of position — distinct from the
  /// audible-position gate in `handleAudibleDecodeLanded`, which only fires the FAST publish path when
  /// the decode is also at/near the current output position. If `Schedule.current` hands back a first
  /// spin that hasn't started airing yet (nothing currently on air), its decode can land well before its
  /// own airtime; the fast path correctly stays silent then, but `handleSpinStarted` needs this flag to
  /// tell a LEGITIMATE later boundary crossing (decode already ready, now truly at position) apart from
  /// the original bug's spurious one (no decode has landed at all yet).
  private var airingSpinDecoded = false
  /// Set when the airing spin's own boundary crossing fires while its decode has not landed yet
  /// (the still-unresolved case `handleSpinStarted` drops). Decode-ahead is driven by the renderer's
  /// position, not eagerly, so for a first spin scheduled well into the future the boundary can fire
  /// before its decode does — the position gate in `handleAudibleDecodeLanded` would then drop that
  /// decode forever too (the spin's fixed scheduled position never satisfies `startFrame <=
  /// latencyFrames`), leaving nothing left to ever publish. This flag lets a late-landing decode
  /// recognize that wall-clock time already passed this spin's airtime and publish anyway.
  private var airingSpinBoundaryCrossed = false
  /// The currently-airing spin's id, recorded only once it successfully ingests (has a download URL) —
  /// mirrors `reportsProgress`'s position-not-id scoping (see `ingest`) so a later spin sharing the same
  /// id as a malformed airing spin can't masquerade as it for the failure fallback below.
  private var airingSpinID: String?
  /// The airing spin's own scheduled position, cached at `ingest()` time (nil for a malformed spin that
  /// never ingests). `mapper` is re-pinned at every boundary crossing (`reanchor`), so this can't be
  /// safely recomputed later from `spin.airtime` — it must be captured once, alongside `airingSpinID`.
  /// Used by `markAiringSpinFailed` to tell a currently-airing spin's failure (publish immediately, same
  /// as today) apart from a future-scheduled first spin's failure (defer until its own boundary crosses —
  /// see that method's doc comment).
  private var airingSpinStartFrame: Int64?
  private var isStopped = false
  private var startupDeadlineTask: Task<Void, Never>?

  /// Local paths of files still referenced by this session (owner feeds these to `pruneCache` as
  /// exclusions so an in-use spin's audio can't be evicted mid-play).
  var activeLocalFilePaths: [String] { Array(localFilePaths.values) }

  /// Called (on the main actor) when a spin boundary is crossed — maps to `State.playing(spin)`.
  var onSpinStarted: ((Spin) -> Void)?
  /// Called (on the main actor) when playback is actually imminent — the airing spin's first
  /// currently-audible decode landed, or its download/decode failed after the renderer had already
  /// started at the startup deadline (so the state machine can't sit in `.loading` forever behind a
  /// renderer that's silently running). NOT fired merely because the startup deadline elapsed with no
  /// decode and no failure yet — the renderer starts silently in that case, and this fires later, from
  /// whichever of those two events happens first. Fires at most once. The owner flips state to `.playing`
  /// here rather than at `start(with:)`, so a slow first download shows `.loading`, not silent `.playing`
  /// (§4.4).
  var onPlaybackStarted: (() -> Void)?
  /// Called (on the main actor) when the live renderer reports a terminal failure (status `.failed`).
  /// Every enqueue after that is a no-op; the owner must surface `State.error` (C13), not stay
  /// silently `.playing`.
  var onRendererFailed: ((Error?) -> Void)?
  /// Called (on the main actor) with the currently-airing spin's download progress (0.0–1.0), matching
  /// the legacy path's `loadSpinWithProgress`. Never fires for upcoming spins, and never fires once
  /// playback has been PUBLISHED — `onPlaybackStarted` fired, OR a later spin's boundary was crossed
  /// first (playback must not regress from `.playing` back to `.loading`, even if the airing spin's own
  /// download never resolves) — it keeps flowing through the startup-deadline silent hole, while the
  /// renderer is running but playback hasn't been published yet.
  var onLoadProgress: ((Float) -> Void)?

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

    wireRenderPipeline()
  }

  /// A spin boundary crossing (`renderer.onSpinStarted`): re-pins the mapping and prunes ended spins
  /// unconditionally, but only notifies the owner (and retires progress reporting) once the crossing is
  /// trustworthy as proof of real audio. Main-actor confined.
  ///
  /// The renderer's boundary observer fires purely from a spin's SCHEDULED position on the timeline
  /// (`SampleBufferStationRenderer.installBoundaryObserver`) — independent of whether that spin's own
  /// decode has landed. For the STILL-UNRESOLVED airing spin with NO decode landed yet at all
  /// (`airingSpinDecoded == false`), that position is at/near the very start of the timeline, so its
  /// boundary can fire the instant the deadline starts the renderer, before any real audio exists.
  /// Forwarding that to `onSpinStarted?` would republish `.playing` during the exact silent pre-decode
  /// hole this PR exists to fix, just via a different callback than the one it guards
  /// (`onPlaybackStarted`) — so it's dropped instead; `onPlaybackStarted` (audible decode / failure) is
  /// this spin's real transition trigger in that case, and covers the same information for the owner.
  ///
  /// But if `Schedule.current` hands back a first spin that hasn't started airing yet (nothing currently
  /// on air), its decode can land well BEFORE its own airtime — `handleAudibleDecodeLanded` correctly
  /// stays silent then (not yet at the audible position), but sets `airingSpinDecoded`. When the boundary
  /// later fires for that spin, the decode is already ready and real audio genuinely starts — dropping it
  /// too would leave the state machine stuck in `.loading` forever, since nothing else would ever publish
  /// for it. So a crossing IS trusted once `airingSpinDecoded` is true, even before `playbackPublished`.
  ///
  /// For a later spin, the boundary crossing is trusted as-is (pre-existing, unchanged semantics) and
  /// also retires progress reporting (`playbackPublished = true`) WITHOUT firing `onPlaybackStarted`: an
  /// upcoming spin can decode early while non-audible (`handleAudibleDecodeLanded` silently drops that
  /// notification) and then become the first audible audio via its own boundary crossing, independent of
  /// whether the airing spin's own download/decode ever resolves; if progress stayed gated on the airing
  /// spin's own resolution, a stale/never-resolving download could keep firing `.loading(progress)` after
  /// the owner already published `.playing` for that later spin — regressing state backward.
  /// `onPlaybackStarted` must NOT also fire here: the owner already treats `onSpinStarted` as its own
  /// `.playing` transition, and firing `onPlaybackStarted` afterward would republish a stale
  /// `.playing(firstSpin)` on top of it.
  ///
  /// The airing spin's own boundary is also dropped once playback is already published — by whichever
  /// path got there first (audible decode, failure fallback, or an earlier legitimate crossing). The
  /// boundary observer fires purely from scheduled position, with no memory of whether it already fired
  /// for this spin, so without this it would forward `onSpinStarted?(spin)` a second time for the exact
  /// same spin the owner already published via `onPlaybackStarted` — a stale duplicate, not a new
  /// transition.
  ///
  /// A crossing is likewise trusted once `airingSpinFailed` is true, even before a decode: a future first
  /// spin's failure defers publish until its own position is reached (see `markAiringSpinFailed`), and
  /// this is that deferred publish firing. It publishes via `onPlaybackStarted`, not by falling through to
  /// `onSpinStarted?(spin)` below — a failed spin never has real audio to report as "started."
  private func handleSpinStarted(_ spin: Spin) {
    reanchor()  // A1: re-pin the mapping to the live playhead at each boundary
    pruneEndedSpins()  // free finished sources so a long session doesn't leak/degrade
    if spin.id == airingSpinID {
      guard !playbackPublished else {
        sampleBufferLog.notice(
          "boundary: spin \(spin.id, privacy: .public) ignored (already published)")
        return
      }
      // A failed airing spin never gets real audio — publish via `onPlaybackStarted` (this spin's
      // failure fallback), not by falling through to `onSpinStarted?(spin)` below, which would tell
      // the owner audio for this exact spin is starting.
      guard !airingSpinFailed else {
        publishPlaybackStarted()
        return
      }
      guard airingSpinDecoded else {
        airingSpinBoundaryCrossed = true
        sampleBufferLog.notice(
          "boundary: spin \(spin.id, privacy: .public) ignored (airing spin not yet decoded)")
        return
      }
    }
    sampleBufferLog.info("boundary: spin \(spin.id, privacy: .public) started")
    playbackPublished = true
    onSpinStarted?(spin)
  }

  /// Test seam: simulates a spin boundary crossing without a real renderer/synchronizer (device-verified,
  /// not unit-tested — see the type doc comment).
  func simulateSpinBoundaryForTesting(_ spin: Spin) {
    handleSpinStarted(spin)
  }

  private func wireRenderPipeline() {
    let renderer = self.renderer
    let pump = self.pump
    let sink = self.sink
    let errorReporter = self.errorReporter
    renderer.onSpinStarted = { [weak self] spin in
      Task { @MainActor in self?.handleSpinStarted(spin) }
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
    sink.onRendererFailed = { [weak self] error in
      Task { @MainActor in self?.onRendererFailed?(error) }
    }
    // §4.4: only a CURRENTLY-AUDIBLE source's first decode starts playback — a future spin decoding
    // first would start the renderer into a silent startup hole. The startup deadline stays as the
    // slow/missing-download fallback.
    pump.onDataPrepared = { [weak self] window in
      Task { @MainActor in
        self?.handleAudibleDecodeLanded(spinID: window.spinID, startFrame: window.startFrame)
      }
    }
    // §4.4: a failed decode renders as silence and the station continues — but it must be REPORTED,
    // not swallowed (a corrupt/unsupported file would otherwise be an invisible dead spin). If it's the
    // AIRING spin, this may also be the only thing that will ever unstick a deadline-started renderer
    // (no decode is ever coming for it), so it also feeds the failure fallback below.
    pump.onDecodeFailed = { [weak self, errorReporter] spinID, error in
      Task { @MainActor in self?.handleAiringSpinFailure(spinID: spinID) }
      Task {
        await errorReporter.reportError(
          error, context: "Sample-buffer decode failed for spin \(spinID); rendering silence",
          level: .warning)
      }
    }
  }

  /// Startup deadline: begin playback even if the first decode hasn't landed, so a slow/missing download
  /// can't hang the station (§4.4). Device-tunable.
  private static let startupDeadline: UInt64 = 2_000_000_000  // 2s

  /// Install the schedule + kick downloads, but DON'T start the renderer yet — start it when the first
  /// decode lands (`pump.onFirstData`) or the startup deadline elapses, to avoid enqueuing a silent
  /// startup hole into the shallow queue before any audio is decoded.
  func start(with spins: [Spin]) {
    // Only the true first (currently-airing) spin's download reports progress. Pin that to POSITION, not
    // id: the first element handed to `start(with:)` is the airing spin, and progress reporting is spent
    // on it regardless of whether it is ingestable — so a malformed (nil-URL) airing spin does not pass
    // its progress reporting to a later spin, even one carrying a duplicate id.
    let scheduled = spins.enumerated().compactMap { index, spin in
      ingest(spin, reportsProgress: index == 0)
    }
    sampleBufferLog.info(
      "controller.start: \(scheduled.count)/\(spins.count) spins scheduled; waiting for first decode"
    )
    renderer.setSchedule(scheduled)
    scheduleInstalled = true
    startupDeadlineTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.startupDeadline)
      guard !Task.isCancelled else { return }
      if self?.rendererStarted == false {
        sampleBufferLog.notice("controller: startup deadline hit before any decode landed")
      }
      self?.startRendererIfNeeded()
    }
  }

  private func startRendererIfNeeded() {
    guard !isStopped, !rendererStarted else { return }
    rendererStarted = true
    sampleBufferLog.notice("controller: starting renderer (first audio ready or deadline)")
    renderer.start()
    // The airing spin may have already failed while we were waiting on the deadline — publish now if
    // that failure is due (see `publishFailureIfDue`), rather than leaving the state machine stuck in
    // `.loading` behind a renderer that's already running.
    publishFailureIfDue()
  }

  /// Test seam: simulates the startup deadline starting the renderer, without a real decode pipeline
  /// (device-verified, not unit-tested — see the type doc comment). Deliberately does NOT publish
  /// playback on its own — see `onPlaybackStarted`'s doc comment.
  func startRendererIfNeededForTesting() {
    startRendererIfNeeded()
  }

  /// §4.4: only a CURRENTLY-AUDIBLE source's first decode starts playback — a future spin decoding first
  /// would start the renderer into a silent startup hole. Starts the renderer if needed (idempotent
  /// no-op if the deadline already did) and publishes playback — covers both the fast path (decode lands
  /// before the deadline) and the deferred deadline path (decode lands after the deadline already
  /// started the renderer silently).
  ///
  /// Position alone (`startFrame <= latencyFrames`) is not sufficient identity proof: on a high-latency
  /// route (e.g. AirPlay, ~2s), a LATER spin scheduled within that latency-compensation window could
  /// decode before the airing spin's own download/decode finishes and satisfy the position check too —
  /// so this also requires `spinID == airingSpinID`, the same identity guard `handleAiringSpinFailure`
  /// already uses.
  private func handleAudibleDecodeLanded(spinID: String, startFrame: Int64) {
    guard spinID == airingSpinID else { return }
    airingSpinDecoded = true
    // Normally only a position at/near the current output frame is "audible." But if this spin's
    // own boundary already crossed with no decode landed, wall-clock time has already passed its
    // scheduled position — the position check would never be satisfied for it, so this late-landing
    // decode is the only remaining signal that will ever publish for it.
    guard startFrame <= latencyFrames || airingSpinBoundaryCrossed else { return }
    startRendererIfNeeded()
    publishPlaybackStarted()
  }

  /// Test seam: simulates a decode landing at the given output start frame for a spin (the airing spin
  /// by default) — the same audible/non-audible gate production uses to decide whether to publish
  /// playback — without a real decode pipeline (device-verified, not unit-tested — see the type doc
  /// comment).
  func simulateDecodeLandedForTesting(spinID: String? = nil, startFrame: Int64) {
    handleAudibleDecodeLanded(spinID: spinID ?? airingSpinID ?? "", startFrame: startFrame)
  }

  /// §4.4 item 3: if the airing spin's download or decode fails, the state machine must never be able to
  /// sit in `.loading` forever behind a renderer that's already running — publish immediately if it is.
  /// If the renderer hasn't started yet (the failure raced ahead of the startup deadline), audio behavior
  /// must not change: just remember it, so the eventual deadline-triggered start (`startRendererIfNeeded`
  /// above) publishes right away instead of waiting on a decode that can never happen.
  private func handleAiringSpinFailure(spinID: String) {
    guard spinID == airingSpinID else { return }
    markAiringSpinFailed()
  }

  /// A currently-airing spin (`airingSpinStartFrame` at/before `latencyFrames`, the common case — a nil
  /// `airingSpinStartFrame` is the malformed-spin path, which never ingests and so has no position to
  /// check either) publishes immediately once the renderer is running, exactly as before: there's nothing
  /// left to wait for. But if `Schedule.current` handed back a first spin that hasn't started airing yet,
  /// its failure can land minutes before its own scheduled position — publishing then would show
  /// `.playing` for audio that was never due yet. Defer to that spin's own boundary crossing instead
  /// (`handleSpinStarted` trusts `airingSpinFailed` the same way it trusts `airingSpinDecoded`), unless
  /// the boundary already crossed first (`airingSpinBoundaryCrossed`), in which case wall-clock time has
  /// already passed this spin's position and there's no boundary crossing left to wait for.
  private func markAiringSpinFailed() {
    airingSpinFailed = true
    guard rendererStarted else { return }
    publishFailureIfDue()
  }

  /// Shared gate for publishing a previously-recorded airing-spin failure, called both when the failure
  /// lands after the renderer is already running (`markAiringSpinFailed`) and when the startup deadline
  /// starts the renderer after a failure already landed (`startRendererIfNeeded`) — both orderings need
  /// the same position/boundary-crossed check, or the deadline path would bypass the deferral above.
  private func publishFailureIfDue() {
    guard airingSpinFailed else { return }
    guard (airingSpinStartFrame ?? latencyFrames) <= latencyFrames || airingSpinBoundaryCrossed
    else {
      return
    }
    publishPlaybackStarted()
  }

  /// Test seam: simulates the given spin's download/decode failing — the same identity check
  /// production uses to scope the failure fallback to the TRUE airing spin — without a real download
  /// or decode pipeline (device-verified, not unit-tested — see the type doc comment).
  func simulateSpinFailureForTesting(spinID: String) {
    handleAiringSpinFailure(spinID: spinID)
  }

  private func publishPlaybackStarted() {
    guard !isStopped, !playbackPublished else { return }
    playbackPublished = true
    onPlaybackStarted?()
  }

  /// Fold in later-discovered upcoming spins (from the station player's 20s poll). Cheap append for
  /// anything beyond the enqueue horizon; the renderer ignores/reports one that lands too late.
  func addUpcoming(_ spins: [Spin]) {
    let scheduled = spins.compactMap { ingest($0, reportsProgress: false) }
    guard !scheduled.isEmpty else { return }
    if scheduleInstalled {
      renderer.appendScheduled(scheduled)
    } else {
      renderer.setSchedule(scheduled)
      scheduleInstalled = true
    }
  }

  func stop() {
    isStopped = true
    startupDeadlineTask?.cancel()
    startupDeadlineTask = nil
    renderer.halt()  // freeze audio immediately, before any re-play starts a fresh sink
    for task in downloadTasks.values { task.cancel() }
    downloadTasks.removeAll()
    localFilePaths.removeAll()
    knownSpinIDs.removeAll()
    renderer.stop()
    pump.cancelAll()
  }

  // MARK: - Private

  /// Register a spin: compute its timeline placement, hand the renderer a silent placeholder snapshot
  /// (so the boundary observer installs now), and kick off download → decode → real snapshot. Returns
  /// the placeholder `Scheduled`, or nil if already known / no URL.
  private func ingest(_ spin: Spin, reportsProgress: Bool)
    -> SampleBufferStationRenderer.Scheduled?
  {
    guard !knownSpinIDs.contains(spin.id) else { return nil }
    guard let remoteUrl = spin.audioBlock.downloadUrl else {
      // A malformed airing spin never reaches here in production (`PlayolaStationPlayer` validates
      // first) — this is the controller's own defense in depth. No download/decode task will ever
      // exist for this spin, so without this, a deadline-started renderer would sit behind
      // `.loading` forever. Call the shared body directly (not `handleAiringSpinFailure`): id-matching
      // doesn't apply here, `airingSpinID` is deliberately never set for a spin that never ingests
      // (the position-not-identity rule above), so a later same-id spin can't inherit its failure.
      if reportsProgress { markAiringSpinFailed() }
      return nil
    }
    knownSpinIDs.insert(spin.id)
    activeSpins[spin.id] = spin
    if reportsProgress { airingSpinID = spin.id }

    let startFrame = mapper.frame(for: spin.airtime)
    if reportsProgress { airingSpinStartFrame = startFrame }
    // The first authored output frame is `latencyFrames` (the timebase's head start), so the first
    // source offset actually rendered is `latencyFrames - startFrame` — decode from there, not from
    // the mapper origin, or a high-latency route's first window mixes to silence (mid-file join
    // included: frames before the write cursor are never enqueued).
    let initialOffset = max(0, latencyFrames - startFrame)
    let envelope = FadeEnvelope(spin: spin)
    let placeholder = SpinPCMWindow(
      spinID: spin.id, startFrame: startFrame, envelope: envelope,
      windowStart: initialOffset, frames: [])

    downloadTasks[spin.id] = Task { [weak self] in
      await self?.download(
        spin: spin, remoteUrl: remoteUrl, startFrame: startFrame, offset: initialOffset,
        reportsProgress: reportsProgress)
      self?.downloadTasks[spin.id] = nil  // release the finished task (spin ids are never re-ingested)
    }

    return SampleBufferStationRenderer.Scheduled(spin: spin, source: placeholder)
  }

  private func download(
    spin: Spin, remoteUrl: URL, startFrame: Int64, offset: Int64, reportsProgress: Bool
  ) async {
    do {
      let localUrl = try await fileDownloadManager.downloadFileAsync(
        remoteUrl: remoteUrl,
        progressHandler: reportsProgress
          ? { [weak self] progress in
            guard let self, !self.playbackPublished else { return }
            self.onLoadProgress?(progress)
          } : nil)
      if Task.isCancelled { return }
      // A download that lands after the spin was stopped/pruned must NOT re-register a stale path or
      // prepare a source the renderer no longer knows about.
      guard !isStopped, activeSpins[spin.id] != nil else { return }
      localFilePaths[spin.id] = localUrl.path
      pump.prepare(spin: spin, fileURL: localUrl, startFrame: startFrame, initialOffset: offset)
    } catch {
      if !(error is CancellationError) {
        // Unstick a deadline-started renderer waiting on a decode that will never come (§4.4 item 3)
        // before the (possibly slower) error report, so the fallback isn't itself gated on that hop.
        handleAiringSpinFailure(spinID: spin.id)
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
    for id in ended {
      activeSpins[id] = nil
      // Drop the download task + cached path too, or `activeLocalFilePaths` keeps excluding every
      // finished file from cache pruning for the whole session (the retained-cache leak).
      downloadTasks[id]?.cancel()
      downloadTasks[id] = nil
      localFilePaths[id] = nil
    }
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
  private let publish: @Sendable (SpinPCMWindow) -> Void
  /// Coalesce decode requests: fill signals every ~85ms, but only ONE decode pass need be queued at a
  /// time (it always decodes to the latest target). Without this the decode queue backs up and the only
  /// current PCM is the eager initial 2s — each spin then plays ~2s and cuts to silence.
  private let decodeRequest = OSAllocatedUnfairLock<(scheduled: Bool, target: Int64)>(
    initialState: (false, 0))

  /// Fired after each source's initial decode lands, with that source's snapshot — the controller
  /// starts the renderer on the first CURRENTLY-AUDIBLE one (avoids both a silent startup hole and a
  /// premature start when a future spin decodes first). Set before any decode begins.
  var onDataPrepared: (@Sendable (SpinPCMWindow) -> Void)?
  /// Fired at most once per spin when its decode fails (setup or incremental); the spin renders as
  /// silence (§4.4) but the failure is surfaced instead of swallowed.
  var onDecodeFailed: (@Sendable (_ spinID: String, _ error: Error) -> Void)?
  private var reportedDecodeFailures: Set<String> = []  // queue-confined

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
        let window = source.snapshot()
        publish(window)
        onDataPrepared?(window)
      } catch {
        // A failed decode contributes silence (the mixer renders nil frames); the station continues.
        if reportedDecodeFailures.insert(spin.id).inserted {
          onDecodeFailed?(spin.id, error)
        }
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
      for (id, source) in sources {
        let target = through - source.startFrame
        guard target > source.decodedThroughOffset, !source.isFullyDecoded else { continue }
        do {
          try source.decode(throughSourceOffset: target)
        } catch {
          if reportedDecodeFailures.insert(id).inserted {
            onDecodeFailed?(id, error)
          }
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
