//
//  SpinPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//
// swiftlint:disable file_length
// `@preconcurrency` lets us hand AVAudioPlayerNode / AVAudioFile (not Sendable)
// to the serial `audioControlQueue` closures. Threading contract: only the
// node/engine *control* calls run off-main, always on that one serial queue,
// and the closures capture node locals — never main-actor `self` state. Mirrors
// PlayolaMainMixer.start().
@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import PlayolaCore
import os

#if os(iOS)
  import QuartzCore
#endif

/// Handles playback of a single spin (audio item) with precise timing control.
///
/// `SpinPlayer` manages the loading, scheduling, and playback of individual audio items
/// with support for:
/// - Precise scheduling at specific timestamps
/// - Volume fading and crossfading
/// - Notifying delegates of playback events
@MainActor
public class SpinPlayer {
  public enum State {
    case available
    case playing
    case loaded
    case loading
  }

  /// Constants used throughout the SpinPlayer
  private enum Constants {
    /// Duration in seconds for volume fade transitions
    static let fadeDuration: Double = 1.5
    /// Number of steps in a fade operation
    static let fadeSteps: Int = 48
    /// Guard time in seconds before scheduling fades
    static let fadeGuardTime: Double = 0.010
    /// Minimum energy threshold for detecting audio
    static let minimumEnergyThreshold: Float = 1e-6
    /// Tap buffer size for start detection
    static let tapBufferSize: AVAudioFrameCount = 1024
    /// Standard audio sample rate used for duration calculations
    static let standardSampleRate: Double = 44100
    /// Minimum valid audio file size in bytes (10KB)
    static let minimumFileSize: Int = 10 * 1024
    /// Buffer time in seconds after spin end before cleanup
    static let cleanupBufferTime: TimeInterval = 1.0
  }

  private static let logger = OSLog(
    subsystem: "fm.playola.playolaCore",
    category: "Player"
  )

  // MARK: - Public Properties
  public var id: UUID = UUID()
  public var spin: Spin? {
    didSet { setClearTimer(spin) }
  }
  /// The PlayolaStationPlayer play() generation that scheduled this player.
  /// Used to ignore playback callbacks from a superseded session.
  var playGeneration: Int = 0
  public weak var delegate: SpinPlayerDelegate?
  public var localUrl: URL? { return currentFile?.url }

  // MARK: - Timer Management
  public var startNotificationTimer: Timer?
  public var clearTimer: Timer?

  // MARK: - Dependencies
  @objc var playolaMainMixer: PlayolaMainMixer = .shared
  private var fileDownloadManager: FileDownloadManaging
  private let errorReporter = PlayolaErrorReporter.shared

  // MARK: - Download State
  private var activeDownloadId: UUID?

  // MARK: - Audio Control Threading
  /// Serial queue for blocking AVAudioEngine / AVAudioPlayerNode control-plane
  /// calls (start/stop/scheduleSegment/play). Running them off the main thread
  /// avoids the App Hangs caused by `awaitIOCycle` blocking the main thread;
  /// keeping them on a single serial queue preserves play-vs-stop ordering now
  /// that they no longer share the main actor's implicit serialization.
  private let audioControlQueue = DispatchQueue(
    label: "fm.playola.spinplayer.audio-control", qos: .userInitiated)

  /// Monotonic token bumped whenever playback is superseded (a new play starts
  /// or the player is cleared/stopped). Captured before an off-main `await` and
  /// re-checked after, so a continuation resumed from a superseded session never
  /// mutates state or notifies the delegate.
  private var playbackEpoch: Int = 0

  /// Thread-safe mirror of `playbackEpoch` so a queued audio-control block can
  /// check, off-main, whether it was superseded before it actually starts the
  /// node — preventing a play() that was queued behind a long IO wait from
  /// restarting audio after a clear()/stop().
  private let atomicEpoch = OSAllocatedUnfairLock(initialState: 0)

  /// Bumps the playback epoch (main-actor truth + thread-safe mirror).
  @discardableResult
  private func bumpEpoch() -> Int {
    playbackEpoch += 1
    let newEpoch = playbackEpoch
    atomicEpoch.withLock { $0 = newEpoch }
    return newEpoch
  }

  /// Marks the start of a new playback attempt, superseding any prior in-flight
  /// (possibly suspended) playback on this player. Returns the epoch to re-check
  /// after each subsequent `await`.
  private func beginPlayback() -> Int {
    bumpEpoch()
  }

  /// Runs a blocking AVAudioPlayerNode/AVAudioEngine control operation on the
  /// serial audio-control queue, off the main thread, and suspends until it
  /// completes. The op is skipped if `epoch` is no longer current by the time
  /// the block runs (a clear()/stop()/newer play superseded it). Capture node
  /// references into locals before calling — do not touch main-actor `self`
  /// state inside `operation`.
  private func runAudioControl(
    epoch: Int, _ operation: @escaping @Sendable () -> Void
  ) async {
    let epochLock = atomicEpoch
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      audioControlQueue.async {
        if epochLock.withLock({ $0 }) == epoch { operation() }
        continuation.resume()
      }
    }
  }

  // MARK: - Playback State
  private var currentVolume: Float = 1.0
  /// Seconds offset into the file where playback started (e.g., when using playNow(from:)).
  private var playbackStartOffset: Double = 0

  public var duration: Double {
    guard let currentFile else { return 0 }
    let audioNodeFileLength = AVAudioFrameCount(currentFile.length)
    return Double(Double(audioNodeFileLength) / Constants.standardSampleRate)
  }

  public var state: SpinPlayer.State = .available {
    didSet { delegate?.player(self, didChangeState: state) }
  }

  // MARK: - Audio Engine Components
  /// An internal instance of AVAudioEngine
  private let engine: AVAudioEngine! = PlayolaMainMixer.shared.engine
  /// The node responsible for playing the audio file
  private let playerNode = AVAudioPlayerNode()
  /// Insert a per-player track mixer so we can automate volume on the audio thread
  private var trackMixer = AVAudioMixerNode()

  // MARK: - Audio Parameter Management
  /// Cached rampable volume parameter for fades/automation
  private var volumeParam: AUParameter?
  private var paramObserverToken: AUParameterObserverToken?
  /// Captured mixer start sample (from the first non-silent tap callback)
  private var scheduledStartSample: AUEventSampleTime?
  /// One-shot tap guards
  private var startTapInstalled = false
  private var didCaptureStart = false

  // MARK: - File Management
  /// The currently playing audio file
  private var currentFile: AVAudioFile? {
    didSet {
      if let file = currentFile {
        loadFile(file)
      }
    }
  }

  public var isPlaying: Bool { return playerNode.isPlaying }

  public var volume: Float {
    get { currentVolume }
    set {
      currentVolume = newValue

      // Always keep the player node at unity; all gain happens on the per-track mixer
      if playerNode.volume != 1.0 { playerNode.volume = 1.0 }

      applyVolumeToAudioParameter(newValue)
    }
  }

  // MARK: - Lifecycle
  init(
    delegate: SpinPlayerDelegate? = nil,
    fileDownloadManager: FileDownloadManaging? = nil
  ) {
    self.fileDownloadManager =
      fileDownloadManager ?? FileDownloadManagerAsync.shared
    self.delegate = delegate

    // Use the centralized audio session management instead of configuring here
    playolaMainMixer.configureAudioSession()

    /// Make connections
    engine.attach(playerNode)
    engine.attach(trackMixer)

    // Graph: playerNode -> per-track mixer -> main mixer
    engine.connect(
      playerNode,
      to: trackMixer,
      format: TapProperties.default.format
    )
    engine.connect(
      trackMixer,
      to: playolaMainMixer.mixerNode,
      format: TapProperties.default.format
    )

    // Baselines
    trackMixer.outputVolume = 1.0
    // Always keep the player node at unity gain
    playerNode.volume = 1.0
    engine.prepare()
    installParamObserverIfNeeded()
  }

  deinit {
    // Cancel any active download
    if let activeDownloadId = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: activeDownloadId)
    }
    if let token = paramObserverToken, let tree = trackMixer.auAudioUnit.parameterTree {
      tree.removeParameterObserver(token)
      paramObserverToken = nil
    }
  }

  /// Reset render anchors so each new spin gets a fresh start capture
  private func resetRenderAnchors() {
    // If a previous start tap was left installed (e.g., we never saw non‑silent audio),
    // remove it now to avoid "CreateRecordingTap" crash on re-install.
    if startTapInstalled {
      trackMixer.removeTap(onBus: 0)
      os_log("🧹 Removed lingering start tap", log: SpinPlayer.logger, type: .info)
    }
    scheduledStartSample = nil
    didCaptureStart = false
    startTapInstalled = false
    os_log("🔄 Reset render anchors for new spin", log: SpinPlayer.logger, type: .info)
  }

  /// Fully tear down and recreate the per-track mixer so any queued AU parameter automation is discarded.
  private func hardResetTrackMixer() {
    // Remove any one-shot start tap to avoid re-install crashes.
    if startTapInstalled {
      trackMixer.removeTap(onBus: 0)
      startTapInstalled = false
    }

    // Remove parameter observer from old AU tree if present.
    if let token = paramObserverToken, let tree = trackMixer.auAudioUnit.parameterTree {
      tree.removeParameterObserver(token)
      paramObserverToken = nil
    }

    // Best-effort state reset on current AU, then detach and replace the node.
    trackMixer.auAudioUnit.reset()
    engine.disconnectNodeInput(trackMixer)
    engine.disconnectNodeOutput(trackMixer)
    engine.detach(trackMixer)

    // Create and attach a fresh mixer node.
    let newMixer = AVAudioMixerNode()
    trackMixer = newMixer
    engine.attach(newMixer)

    // Reconnect playerNode -> trackMixer -> main mixer
    engine.connect(
      playerNode,
      to: newMixer,
      format: TapProperties.default.format
    )
    engine.connect(
      newMixer,
      to: playolaMainMixer.mixerNode,
      format: TapProperties.default.format
    )

    // Clear cached parameter handles and render anchors; this node is brand new.
    volumeParam = nil
    scheduledStartSample = nil
    didCaptureStart = false

    // Reinstall the parameter observer on the fresh AU as needed.
    installParamObserverIfNeeded()
  }

  // MARK: - Playback Control

  public func stop() {
    os_log(
      "🛑 SpinPlayer.stop() called - ID: %@, spin: %@",
      log: SpinPlayer.logger,
      type: .info,
      self.id.uuidString,
      self.spin?.id ?? "nil"
    )

    // Cancel any active download
    if let activeDownloadId = activeDownloadId {
      os_log(
        "Cancelling download ID: %@ for spin: %@",
        log: SpinPlayer.logger,
        type: .info,
        activeDownloadId.uuidString,
        self.spin?.id ?? "nil"
      )
      _ = fileDownloadManager.cancelDownload(id: activeDownloadId)
      self.activeDownloadId = nil
    }

    clear()
  }

  private func stopAudio() {
    // Only stop if the engine is running - no need to start it just to stop
    guard engine.isRunning else { return }
    // Enqueue on the serial audio-control queue so this stop is mutually
    // exclusive with — and ordered after — any in-flight off-main play()/
    // scheduleSegment for the same node. That ordering is what prevents a play
    // that was queued behind a long IO wait from leaving orphaned audio after
    // clear()/stop(). Fire-and-forget: teardown needn't be awaited, and the
    // epoch bump in clear() already blocks stale main-actor state writes.
    //
    // Residual (accepted Option-A scope): hardResetTrackMixer() still runs on
    // the main actor in clear(), so its graph surgery is not serialized against
    // these queue blocks. playerNode itself is never detached there (only the
    // trackMixer is recreated), and AVAudioEngine supports node ops / graph
    // reconfiguration while running, so this is safe; full serialization of the
    // graph teardown would be the Option-B follow-up.
    let node = playerNode
    audioControlQueue.async {
      node.stop()
      node.reset()
    }
  }

  private func clear() {
    os_log(
      "Clearing SpinPlayer - ID: %@",
      log: SpinPlayer.logger,
      type: .debug,
      self.id.uuidString
    )

    // Supersede any in-flight (possibly suspended) playback so a resumed
    // continuation can't write state or notify, and any queued audio-control
    // block skips its play(), after we've cleared.
    bumpEpoch()

    stopAudio()

    hardResetTrackMixer()
    clearTimers()
    resetRenderAnchors()

    self.spin = nil
    self.currentFile = nil
    self.state = .available
    self.volume = 1.0
    self.playbackStartOffset = 0
  }

  func clearTimers() {
    os_log(
      "Clearing timers for SpinPlayer - ID: %@",
      log: SpinPlayer.logger,
      type: .debug,
      self.id.uuidString
    )

    // Invalidate and clear start notification timer atomically
    if let timer = startNotificationTimer {
      os_log(
        "Invalidating start notification timer",
        log: SpinPlayer.logger,
        type: .debug
      )
      timer.invalidate()
      startNotificationTimer = nil
    }

    // Invalidate and clear clear timer atomically
    if let timer = clearTimer {
      os_log(
        "Invalidating clear timer",
        log: SpinPlayer.logger,
        type: .debug
      )
      timer.invalidate()
      clearTimer = nil
    }

  }

  /// Plays the loaded spin immediately from the specified position.
  ///
  /// This method:
  /// 1. Ensures the audio engine is started
  /// 2. Calculates the correct position in samples
  /// 3. Schedules and starts playback from that position
  /// 4. Notifies the delegate that playback has started
  ///
  /// - Parameters:
  ///   - from: Position in seconds from the beginning of the audio to start playback
  ///   - to: Optional end position in seconds (not implemented in current version)
  ///
  /// If this method is called on a spin that is not loaded, playback will not start.
  public func playNow(from: Double, to: Double? = nil) async {
    let epoch = beginPlayback()
    os_log(
      "Starting playback from position %f",
      log: SpinPlayer.logger,
      type: .info,
      from
    )
    // Record that we're starting mid-file so fades can be shifted appropriately
    self.playbackStartOffset = from
    // Callers must await ensureAudioSessionConfigured() before calling playNow.
    // The fire-and-forget fallback avoids a crash but may still race.
    assert(
      playolaMainMixer.audioSessionManager.isConfigured,
      "Audio session must be configured before calling playNow — call ensureAudioSessionConfigured() first"
    )
    playolaMainMixer.configureAudioSession()

    do {
      // Start the engine off the main thread (AUIOClient_StartIO blocks the
      // caller on cold hardware init). No-op if already running.
      if !engine.isRunning {
        try await playolaMainMixer.start()
      }
    } catch {
      // If superseded, a stop()/clear() likely caused this failure (e.g. session
      // torn down) — don't report stale noise or overwrite the new state.
      guard epoch == playbackEpoch else { return }
      Task {
        await errorReporter.reportError(
          error,
          context: "Failed to start playback at position \(from)s",
          level: .error
        )
      }
      self.state = .available
      return
    }

    // A stop()/clear() (or newer play) may have superseded us while the engine
    // started off-main.
    guard epoch == playbackEpoch else { return }
    guard let audioFile = validateAndGetCurrentFile() else { return }

    await scheduleAndPlaySegment(audioFile: audioFile, from: from, epoch: epoch)

    guard epoch == playbackEpoch else { return }
    self.state = .playing
    if let spin {
      delegate?.player(self, startedPlaying: spin)
    }
    os_log(
      "Successfully started playback",
      log: SpinPlayer.logger,
      type: .info
    )
  }

  private func validateAndGetCurrentFile() -> AVAudioFile? {
    guard let currentFile = currentFile else {
      os_log(
        "Cannot play - audio file was cleared (likely by stop())",
        log: SpinPlayer.logger,
        type: .info
      )
      self.state = .available
      return nil
    }
    return currentFile
  }

  private func scheduleAndPlaySegment(audioFile: AVAudioFile, from: Double, epoch: Int) async {
    // Capture main-actor state into locals so the off-main block never touches
    // `self`. `playerNode.outputFormat`/`stop`/`play` can each block on the
    // audio IO cycle, so the whole sequence runs on the serial control queue.
    let node = playerNode
    let fileDuration = duration

    await runAudioControl(epoch: epoch) {
      let sampleRate = node.outputFormat(forBus: 0).sampleRate
      let newSampleTime = AVAudioFramePosition(sampleRate * from)
      let framesToPlay = AVAudioFrameCount(Float(sampleRate) * Float(fileDuration))

      // stop the player, schedule the segment, restart the player
      // Volume is already set before playNow is called
      node.stop()
      node.scheduleSegment(
        audioFile,
        startingFrame: newSampleTime,
        frameCount: framesToPlay,
        at: nil,
        completionHandler: nil
      )
      node.play()
    }
  }

  // MARK: - Loading and Download Management

  /// Loads a spin into the player and prepares it for playback.
  ///
  /// This method:
  /// 1. Downloads the audio file if not already cached
  /// 2. Prepares the audio for playback
  /// 3. Schedules the spin to play at its designated airtime
  /// 4. Sets up any volume fades defined in the spin
  ///
  /// - Parameters:
  ///   - spin: The spin to load and prepare for playback
  ///   - onDownloadProgress: Optional callback providing download progress updates (0.0 to 1.0)
  ///
  /// - Returns: A result containing either the local URL of the loaded audio file, or an error
  public func load(_ spin: Spin, onDownloadProgress: ((Float) -> Void)? = nil)
    async -> Result<
      URL, Error
    >
  {
    os_log("Loading spin: %@", log: SpinPlayer.logger, type: .info, spin.id)

    self.state = .loading
    self.spin = spin

    guard let audioFileUrl = spin.audioBlock.downloadUrl else {
      return .failure(await handleMissingDownloadUrl(for: spin))
    }

    cancelActiveDownload()

    return await withCheckedContinuation { continuation in
      self.activeDownloadId = fileDownloadManager.downloadFile(
        remoteUrl: audioFileUrl,
        progressHandler: onDownloadProgress ?? { _ in },
        completion: { [weak self] result in
          self?.handleDownloadCompletion(result: result, spin: spin, continuation: continuation)
        }
      )
    }
  }

  private func handleMissingDownloadUrl(for spin: Spin) async -> Error {
    let error = NSError(
      domain: "fm.playola.PlayolaPlayer",
      code: 400,
      userInfo: [
        NSLocalizedDescriptionKey: "Invalid audio file URL in spin",
        "spinId": spin.id,
        "audioBlockId": spin.audioBlock.id,
        "audioBlockTitle": spin.audioBlock.title,
      ]
    )
    Task {
      await errorReporter.reportError(
        error,
        context: "Missing download URL",
        level: .error
      )
    }
    self.state = .available
    return error
  }

  private func cancelActiveDownload() {
    if let activeDownloadId = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: activeDownloadId)
      self.activeDownloadId = nil
    }
  }

  private func handleDownloadCompletion(
    result: Result<URL, FileDownloadError>,
    spin: Spin,
    continuation: CheckedContinuation<Result<URL, Error>, Never>
  ) {

    switch result {
    case .success(let localUrl):
      handleSuccessfulDownload(localUrl: localUrl, spin: spin, continuation: continuation)
    case .failure(let error):
      handleFailedDownload(error: error, continuation: continuation)
    }
  }

  private func handleSuccessfulDownload(
    localUrl: URL,
    spin: Spin,
    continuation: CheckedContinuation<Result<URL, Error>, Never>
  ) {
    Task { @MainActor in
      await self.loadFile(with: localUrl)

      // Ensure audio session is configured and engine is started before playback.
      // Starting the engine here (off-main via playolaMainMixer.start) avoids the
      // AUIOClient_StartIO main-thread hang on cold first-play.
      do {
        try await self.playolaMainMixer.ensureAudioSessionConfigured()
        try await self.playolaMainMixer.start()
      } catch {
        // ensureAudioSessionConfigured / start already reported to Sentry; skip playback
        self.clear()
        continuation.resume(returning: .failure(error))
        return
      }

      // A stop()/clear() or a newer load() may have superseded this download
      // while we were suspended on the awaits above. If the player no longer
      // owns this spin, abandon playback so we don't drive stale audio.
      guard self.spin?.id == spin.id else {
        continuation.resume(returning: .success(localUrl))
        return
      }

      // Determine what to do based on the spin's timing state
      switch spin.playbackTiming {
      case .future:
        // Spin is in the future - schedule it
        self.volume = spin.startingVolume
        await self.schedulePlay(at: spin.airtime)

      case .playing:
        // Spin should be currently playing - start from current position
        let currentDate = spin.dateProvider.now()
        self.volume = spin.volumeAtDate(currentDate)

        let currentTimeInSeconds = currentDate.timeIntervalSince(spin.airtime)
        await self.playNow(from: currentTimeInSeconds)

      case .tooLateToStart, .past:
        // Spin has already finished or has too little time left - skip it entirely
        os_log(
          "Spin %@ download completed too late (timing: %@) - skipping",
          log: SpinPlayer.logger,
          type: .info,
          spin.id,
          String(describing: spin.playbackTiming)
        )
        // Clean up everything since we're not going to play this spin
        self.clear()
        continuation.resume(returning: .success(localUrl))
        return
      }

      // schedulePlay/playNow may have suspended on their own off-main awaits;
      // re-check ownership before the final (unguarded) state writes.
      guard self.spin?.id == spin.id else {
        continuation.resume(returning: .success(localUrl))
        return
      }

      self.scheduleFades(spin)
      self.state = .loaded
      continuation.resume(returning: .success(localUrl))
    }
  }

  private func handleFailedDownload(
    error: FileDownloadError,
    continuation: CheckedContinuation<Result<URL, Error>, Never>
  ) {
    Task { @MainActor in
      await self.errorReporter.reportError(
        error,
        context: "Download failed",
        level: .error
      )
    }
    self.state = .available
    continuation.resume(returning: .failure(error))
  }

  // MARK: - Volume and Audio Parameter Management

  /// Resolve and cache the rampable volume parameter we'll use for automation on `trackMixer`.
  private func resolveVolumeParam() -> AUParameter? {
    if let param = volumeParam { return param }
    guard let tree = trackMixer.auAudioUnit.parameterTree else { return nil }
    // Prefer output.0 volume, else input.0.0, else any rampable "volume"/"0", else first rampable.
    let params = tree.allParameters.filter { $0.flags.contains(.flag_CanRamp) }
    if let byOutput = params.first(where: { $0.keyPath.lowercased().contains("output.0") }) {
      volumeParam = byOutput
      return byOutput
    }
    if let byInput0 = params.first(where: { $0.keyPath.lowercased().contains("input.0.0") }) {
      volumeParam = byInput0
      return byInput0
    }
    if let byName = params.first(where: { $0.identifier.lowercased() == "volume" }) {
      volumeParam = byName
      return byName
    }
    if let byZero = params.first(where: { $0.identifier == "0" }) {
      volumeParam = byZero
      return byZero
    }
    if let any = params.first {
      volumeParam = any
      return any
    }
    return nil
  }

  private func applyVolumeToAudioParameter(_ newValue: Float) {
    let target = newValue

    if let param = resolveVolumeParam() {
      param.setValue(AUValue(target), originator: nil, atHostTime: mach_absolute_time())
      logVolumeSuccess(userVolume: newValue, paramVolume: target, paramAddress: param.address)
    } else {
      logVolumeFailure(attemptedVolume: newValue)
    }
  }

  private func logVolumeSuccess(
    userVolume: Float, paramVolume: Float, paramAddress: AUParameterAddress
  ) {
    os_log(
      "🔊 mixer volume set → user=%.3f (param=%.3f) addr=%llu",
      log: SpinPlayer.logger, type: .info, userVolume, paramVolume, paramAddress)
    print("🔊 Volume set to user=\(userVolume), param=\(paramVolume)")
  }

  private func logVolumeFailure(attemptedVolume: Float) {
    os_log(
      "⚠️ mixer volume set failed (no rampable param)",
      log: SpinPlayer.logger, type: .error)
    print("⚠️ Volume set failed (no rampable param), attempted user=\(attemptedVolume)")
  }

  // MARK: - Fade Management

  /// Install a one-shot tap to capture the first non-silent render on `trackMixer`,
  /// establishing `scheduledStartSample` so fades can be scheduled in the audio sample domain.
  private func installStartTapIfNeeded(pendingFades: [(offset: Double, to: Float)]) {
    guard !startTapInstalled else { return }
    startTapInstalled = true
    ensureEngineRunning()
    didCaptureStart = false

    trackMixer.installTap(onBus: 0, bufferSize: Constants.tapBufferSize, format: nil) {
      [weak self] buffer, time in
      self?.handleTapBuffer(buffer: buffer, time: time, pendingFades: pendingFades)
    }
  }

  private func ensureEngineRunning() {
    guard !engine.isRunning else { return }
    do {
      playolaMainMixer.configureAudioSession()
      try engine.start()
    } catch {
      os_log(
        "⚠️ Could not start engine before installing tap: %{public}@",
        log: SpinPlayer.logger, type: .error, String(describing: error))
    }
  }

  private func handleTapBuffer(
    buffer: AVAudioPCMBuffer, time: AVAudioTime, pendingFades: [(offset: Double, to: Float)]
  ) {
    guard !didCaptureStart else { return }

    // Require some energy to avoid preroll silence
    guard bufferHasEnergy(buffer) else { return }

    // Only capture minimal data in the tap callback - no heavy work here!
    // Calling removeTap or doing logging/parameter scheduling from within
    // the tap callback can deadlock with playerNode.stop() on the main thread.
    didCaptureStart = true
    scheduledStartSample = AUEventSampleTime(time.sampleTime)
    let hostTime = time.hostTime

    // Dispatch all heavy work to main thread to avoid deadlock
    DispatchQueue.main.async { [weak self] in
      self?.finishStartCaptureOnMain(hostTime: hostTime, pendingFades: pendingFades)
    }
  }

  /// Complete the start capture on main thread where it's safe to remove taps and schedule fades.
  @MainActor
  private func finishStartCaptureOnMain(
    hostTime: UInt64,
    pendingFades: [(offset: Double, to: Float)]
  ) {
    // Remove the tap (safe to do on main thread, not inside the tap callback)
    if startTapInstalled {
      trackMixer.removeTap(onBus: 0)
      startTapInstalled = false
    }

    // Ensure a known baseline on the exact host time of first render
    setInitialVolume(at: hostTime)

    // Schedule any fades that were waiting for start capture
    scheduleFadesAtStartIfNeeded(pendingFades)
  }

  private func bufferHasEnergy(_ buffer: AVAudioPCMBuffer) -> Bool {
    guard let ch = buffer.floatChannelData?.pointee else { return false }
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return false }

    var acc: Float = 0
    for i in 0..<frameCount { acc += ch[i] * ch[i] }
    let rms = sqrt(acc / Float(frameCount))
    return rms > Constants.minimumEnergyThreshold
  }

  private func setInitialVolume(at hostTime: UInt64) {
    guard let param = resolveVolumeParam() else { return }

    let userInitial: Float
    if let spin = self.spin {
      let ms = Int((self.playbackStartOffset * 1000.0).rounded())
      userInitial = spin.volumeAt(ms)
    } else {
      userInitial = self.currentVolume
    }

    let paramInitial = userInitial
    param.setValue(AUValue(paramInitial), originator: nil, atHostTime: hostTime)
    os_log(
      "🔧 Baseline mixer volume at start → user=%.3f (param=%.3f) addr=%llu host=%llu",
      log: SpinPlayer.logger, type: .info,
      userInitial, paramInitial, param.address, hostTime)
  }

  /// Queue stepwise fades in the audio render thread using the AU's scheduleParameterBlock.
  private func scheduleFadesAtStartIfNeeded(_ fades: [(offset: Double, to: Float)]) {
    installParamObserverIfNeeded()
    guard let start = scheduledStartSample,
      let param = resolveVolumeParam()
    else { return }
    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock

    // Establish the intended starting value in PARAM domain (now == user space)
    let userStart: Float = {
      if let currentSpin = spin {
        let ms = Int((playbackStartOffset * 1000.0).rounded())
        return currentSpin.volumeAt(ms)
      } else {
        return currentVolume
      }
    }()
    var fromParam = userStart

    for (offset, targetUser) in fades {
      let toParam = targetUser
      var when = start + AUEventSampleTime(offset * sr)
      if let rt = trackMixer.lastRenderTime {
        let nowSample = AUEventSampleTime(rt.sampleTime)
        let guardFrames = AUEventSampleTime(sr * Constants.fadeGuardTime)
        if when <= nowSample + guardFrames { when = nowSample + guardFrames }
      }

      let duration: Double = Constants.fadeDuration
      let steps = Constants.fadeSteps
      let totalFrames = AUEventSampleTime(duration * sr)
      let framesPerStep = max(AUEventSampleTime(1), totalFrames / AUEventSampleTime(steps))

      // build steps from the *previous target* to this target (both in PARAM domain)
      for i in 0...steps {
        let progress = Double(i) / Double(steps)
        let value = AUValue(fromParam + Float(progress) * (toParam - fromParam))
        schedule(when + AUEventSampleTime(i) * framesPerStep, 0, param.address, value)
      }

      fromParam = toParam  // next fade starts where this one ends
    }
  }

  /// Install a render-thread parameter observer for `trackMixer` so we can log every step that the AU applies.
  private func installParamObserverIfNeeded() {
    guard paramObserverToken == nil, let tree = trackMixer.auAudioUnit.parameterTree else { return }
    paramObserverToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
      let ht = mach_absolute_time()
      // If we have a cached volumeParam, annotate when the observed address matches it.
      let matchMark: String
      if let addr = self?.volumeParam?.address, addr == address {
        matchMark = " (VOL)"
      } else {
        matchMark = ""
      }
      os_log(
        "🎯 PARAM OBS: addr=%llu -> %.3f atHost=%llu%{public}@",
        log: SpinPlayer.logger, type: .info, address, value, ht, matchMark)
      print(
        "🎯 PARAM OBS: addr=\(address) -> \(String(format: "%.3f", value)) atHost=\(ht)\(matchMark)")
    })
  }

  /// Result of converting a wall-clock airtime into the player node's sample
  /// timeline. `missingRenderTime` is true when the node had no `lastRenderTime`
  /// (the caller reports it from the main actor).
  private struct ScheduledTime {
    let avAudioTime: AVAudioTime
    let missingRenderTime: Bool
  }

  /// Pure conversion safe to run off the main thread. `outputFormat`/
  /// `lastRenderTime` reads can block on the audio IO cycle, so this runs on the
  /// serial control queue. Does no error reporting — see `ScheduledTime`.
  private nonisolated static func scheduledTime(for date: Date, node: AVAudioPlayerNode)
    -> ScheduledTime
  {
    let outputFormat = node.outputFormat(forBus: 0)
    guard let lastRenderTime = node.lastRenderTime else {
      return ScheduledTime(
        avAudioTime: AVAudioTime(sampleTime: 0, atRate: outputFormat.sampleRate),
        missingRenderTime: true
      )
    }

    let now = lastRenderTime.sampleTime
    let secsUntilDate = date.timeIntervalSinceNow
    return ScheduledTime(
      avAudioTime: AVAudioTime(
        sampleTime: now + Int64(secsUntilDate * outputFormat.sampleRate),
        atRate: outputFormat.sampleRate
      ),
      missingRenderTime: false
    )
  }

  /// Schedules `playerNode.play(at:)` for a future airtime, computing the sample
  /// time and issuing the (potentially blocking) play off the main thread.
  /// Skips the play if `epoch` was superseded before the block ran. Returns
  /// whether the node was missing a render time so the caller can report.
  private func playFuture(at scheduledDate: Date, epoch: Int) async -> Bool {
    let node = playerNode
    let epochLock = atomicEpoch
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      audioControlQueue.async {
        guard epochLock.withLock({ $0 }) == epoch else {
          continuation.resume(returning: false)
          return
        }
        let scheduled = SpinPlayer.scheduledTime(for: scheduledDate, node: node)
        node.play(at: scheduled.avAudioTime)
        continuation.resume(returning: scheduled.missingRenderTime)
      }
    }
  }

  private func reportMissingRenderTime() {
    let error = NSError(
      domain: "fm.playola.PlayolaPlayer",
      code: 500,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Could not get last render time from player node"
      ]
    )
    Task {
      await errorReporter.reportError(
        error,
        context: "Missing render time",
        level: .warning
      )
    }
  }

  // MARK: - Scheduled Playback

  /// schedule a future play from the beginning of the file
  /// Schedule playback to start at a specific time
  public func schedulePlay(at scheduledDate: Date) async {
    let epoch = beginPlayback()
    do {
      try await prepareAudioEngine(scheduledDate: scheduledDate)
      guard epoch == playbackEpoch else { return }
      try validateAudioFile()
    } catch {
      if epoch == playbackEpoch { reportScheduleError(error) }
      return
    }

    // Scheduled plays always start from the top of the file
    self.playbackStartOffset = 0

    let scheduledSpinId = spin?.id
    let missingRenderTime = await playFuture(at: scheduledDate, epoch: epoch)

    // A stop()/clear() (or newer play) may have superseded us off-main.
    guard epoch == playbackEpoch else { return }
    if missingRenderTime { reportMissingRenderTime() }

    setupNotificationTimer(scheduledDate: scheduledDate, scheduledSpinId: scheduledSpinId)
    logScheduleComplete(scheduledDate: scheduledDate)
  }

  private func prepareAudioEngine(scheduledDate: Date) async throws {
    os_log(
      "Scheduling play at %@",
      log: SpinPlayer.logger,
      type: .info,
      ISO8601DateFormatter().string(from: scheduledDate)
    )

    // Callers must await ensureAudioSessionConfigured() before calling schedulePlay.
    assert(
      playolaMainMixer.audioSessionManager.isConfigured,
      "Audio session must be configured before calling schedulePlay — call ensureAudioSessionConfigured() first"
    )
    playolaMainMixer.configureAudioSession()
    // Start the engine off the main thread to avoid blocking on AUIOClient_StartIO.
    if !engine.isRunning {
      try await playolaMainMixer.start()
    }
  }

  private func validateAudioFile() throws {
    guard self.currentFile != nil else {
      let error = NSError(
        domain: "fm.playola.PlayolaPlayer",
        code: 400,
        userInfo: [
          NSLocalizedDescriptionKey: "No audio file loaded when trying to schedule playback"
        ]
      )
      Task {
        await errorReporter.reportError(
          error,
          context: "Missing audio file for scheduled playback",
          level: .error
        )
      }
      throw error
    }
  }

  private func setupNotificationTimer(scheduledDate: Date, scheduledSpinId: String?) {
    self.startNotificationTimer = Timer(
      fire: scheduledDate,
      interval: 0,
      repeats: false
    ) { [weak self] timer in
      timer.invalidate()
      os_log("⏰ Timer fired", log: SpinPlayer.logger, type: .info)

      guard let self = self else {
        os_log(
          "⚠️ Timer fired but SpinPlayer deallocated",
          log: SpinPlayer.logger,
          type: .default
        )
        return
      }

      Task { @MainActor in
        self.handleTimerFired(timer: timer, scheduledSpinId: scheduledSpinId)
      }
    }

    RunLoop.main.add(self.startNotificationTimer!, forMode: .default)
  }

  @MainActor
  private func handleTimerFired(timer: Timer, scheduledSpinId: String?) {
    guard self.startNotificationTimer === timer,
      let spin = self.spin,
      spin.id == scheduledSpinId
    else {
      os_log("⚠️ Timer invalid or spin changed", log: SpinPlayer.logger, type: .default)
      return
    }
    handleSuccessfulTimerFire(spin: spin)
  }

  private func handleSuccessfulTimerFire(spin: Spin) {
    os_log("✅ Timer fired successfully", log: SpinPlayer.logger, type: .info)

    self.startNotificationTimer = nil
    self.state = .playing
    self.delegate?.player(self, startedPlaying: spin)
  }

  private func logScheduleComplete(scheduledDate: Date) {
    os_log(
      "Added timer to RunLoop for spin: %@ scheduled at %@",
      log: SpinPlayer.logger,
      type: .debug,
      self.spin?.id ?? "nil",
      ISO8601DateFormatter().string(from: scheduledDate)
    )
  }

  private func reportScheduleError(_ error: Error) {
    Task {
      await errorReporter.reportError(
        error,
        context: "Failed to schedule playback",
        level: .error
      )
    }
  }

  // MARK: - File Loading

  /// Loads an AVAudioFile into the current player node
  private func loadFile(_ file: AVAudioFile) {
    resetRenderAnchors()
    playerNode.scheduleFile(file, at: nil)
  }

  public func loadFile(with url: URL) async {
    os_log(
      "Loading audio file: %@",
      log: SpinPlayer.logger,
      type: .info,
      url.lastPathComponent
    )

    do {
      let fileSize = try validateFileExistsAndGetSize(url)
      try await createAudioFileFromValidatedURL(url, fileSize: fileSize)
    } catch {
      await handleFileLoadError(error)
    }
  }

  private func validateFileExistsAndGetSize(_ url: URL) throws -> Int {
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: url.path) else {
      let error = FileDownloadError.fileNotFound(url.path)
      Task {
        await errorReporter.reportError(
          error,
          context: "Audio file not found at path",
          level: .error
        )
      }
      self.state = .available
      throw error
    }

    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0

    try validateFileSize(fileSize, url: url, fileManager: fileManager)
    return fileSize
  }

  private func validateFileSize(_ fileSize: Int, url: URL, fileManager: FileManager) throws {
    if fileSize < Constants.minimumFileSize {
      let error = FileDownloadError.downloadFailed(
        "Audio file is too small: \(fileSize) bytes"
      )
      Task {
        await errorReporter.reportError(
          error,
          context: "Suspiciously small file detected: \(url.lastPathComponent)",
          level: .error
        )
      }
      try? fileManager.removeItem(at: url)
      self.state = .available
      throw error
    }
  }

  private func createAudioFileFromValidatedURL(_ url: URL, fileSize: Int) async throws {
    do {
      currentFile = try AVAudioFile(forReading: url)
      logSuccessfulLoad(url)
    } catch let audioError as NSError {
      await handleAudioFileCreationError(audioError, url: url, fileSize: fileSize)
      throw audioError
    }
  }

  private func logSuccessfulLoad(_ url: URL) {
    os_log(
      "Successfully loaded audio file: %@",
      log: SpinPlayer.logger,
      type: .info,
      url.lastPathComponent
    )
  }

  private func handleAudioFileCreationError(_ audioError: NSError, url: URL, fileSize: Int) async {
    let contextInfo =
      "Failed to load audio file: \(url.lastPathComponent) (size: \(fileSize) bytes)"

    if audioError.domain == "com.apple.coreaudio.avfaudio" {
      await handleCoreAudioError(audioError, url: url, contextInfo: contextInfo)
    } else {
      await reportAudioError(audioError, contextInfo: contextInfo)
    }

    self.state = .available
  }

  private func handleCoreAudioError(_ audioError: NSError, url: URL, contextInfo: String) async {
    let fileManager = FileManager.default

    switch audioError.code {
    case 1_954_115_647:  // 'fmt?' in ASCII - format error
      Task {
        await errorReporter.reportError(
          audioError,
          context: "\(contextInfo) - Invalid audio format or corrupt file",
          level: .error
        )
      }
      try? fileManager.removeItem(at: url)
    default:
      await reportAudioError(audioError, contextInfo: contextInfo)
    }
  }

  private func reportAudioError(_ audioError: NSError, contextInfo: String) async {
    Task {
      await errorReporter.reportError(
        audioError,
        context: contextInfo,
        level: .error
      )
    }
  }

  private func handleFileLoadError(_ error: Error) async {
    let shouldReport =
      !error.localizedDescription.contains("too small")
      && !error.localizedDescription.contains("not found")

    if shouldReport {
      Task {
        await errorReporter.reportError(
          error,
          context: "File validation failed",
          level: .error
        )
      }
    }
    self.state = .available
  }

  public func scheduleFades(_ spin: Spin) {
    // Convert Spin fades to offsets (seconds) relative to *this* playback start
    // If we started mid-file (playNow(from:)), shift fades left by that offset and drop past ones
    let fades: [(offset: Double, to: Float)] = spin.fades.compactMap { fade in
      let original = Double(fade.atMS) / 1000.0
      let adjusted = original - playbackStartOffset
      // Ignore fades that would have occurred before we started
      guard adjusted >= 0 else { return nil }
      return (adjusted, fade.toVolume)
    }

    // If we already captured the mixer start, schedule immediately.
    if scheduledStartSample != nil {
      scheduleFadesAtStartIfNeeded(fades)
      return
    }

    // Otherwise, install a one-shot tap to capture the true start and then schedule.
    installStartTapIfNeeded(pendingFades: fades)
  }

  // MARK: - Timer Management

  private func setClearTimer(_ spin: Spin?) {
    guard let endtime = spin?.endtime else {
      self.clearTimer?.invalidate()
      return
    }

    // for now, fire a timer. Later we should try and use a callback
    self.clearTimer = Timer(
      fire: endtime.addingTimeInterval(Constants.cleanupBufferTime),
      interval: 0,
      repeats: false,
      block: { [weak self] timer in
        // Always invalidate timer first
        timer.invalidate()

        guard let self = self else { return }

        Task { @MainActor in
          // Validate timer is still active
          guard self.clearTimer === timer else { return }

          // Clear the timer reference since it's now invalid
          self.clearTimer = nil

          // clear() handles stopAudio() internally, no need to call it twice
          self.clear()
        }
      }
    )
    RunLoop.main.add(self.clearTimer!, forMode: .default)
  }
}

// swiftlint:enable file_length
