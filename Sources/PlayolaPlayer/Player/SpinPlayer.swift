//
//  SpinPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//
// swiftlint:disable file_length
import AVFoundation
import AudioToolbox
import Foundation
import os.log

#if os(iOS)
  import QuartzCore
#endif

/// Handles playback of a single spin (audio item) with precise timing control.
///
/// `SpinPlayer` manages the loading, scheduling, and playback of individual audio items
/// with support for:
/// - Precise scheduling at specific timestamps
/// - Volume fading and crossfading
/// - Audio normalization
/// - Notifying delegates of playback events
@MainActor
public class SpinPlayer {
  public enum State {
    case available
    case playing
    case loaded
    case loading
  }
  private static let logger = OSLog(
    subsystem: "fm.playola.playolaCore",
    category: "Player"
  )

  public var id: UUID = UUID()
  public var spin: Spin? {
    didSet { setClearTimer(spin) }
  }

  public var startNotificationTimer: Timer?
  public var clearTimer: Timer?
  public var fadeTimers = Set<Timer>()

  #if os(iOS)
    private var activeDisplayLink: CADisplayLink?
  #else
    private var fadeUpdateTimer: Timer?
  #endif
  private var activeFades: Set<FadeOperation> = []

  public var localUrl: URL? { return currentFile?.url }

  // dependencies
  @objc var playolaMainMixer: PlayolaMainMixer = .shared
  private var fileDownloadManager: FileDownloadManaging
  private let errorReporter = PlayolaErrorReporter.shared

  // Track active download ID
  private var activeDownloadId: UUID?

  // Mixer-driven volume state
  private var currentVolume: Float = 1.0
  /// Seconds offset into the file where playback started (e.g., when using playNow(from:)).
  private var playbackStartOffset: Double = 0

  public weak var delegate: SpinPlayerDelegate?

  public var duration: Double {
    guard let currentFile else { return 0 }
    let audioNodeFileLength = AVAudioFrameCount(currentFile.length)
    return Double(Double(audioNodeFileLength) / 44100)
  }

  public var state: SpinPlayer.State = .available {
    didSet { delegate?.player(self, didChangeState: state) }
  }

  /// An internal instance of AVAudioEngine
  private let engine: AVAudioEngine! = PlayolaMainMixer.shared.engine

  /// The node responsible for playing the audio file
  private let playerNode = AVAudioPlayerNode()

  /// Per-file loudness normalization stage. We use an EQ solely for its `globalGain` which
  /// supports boosts up to +24 dB (unlike AVAudioMixerNode which tops out at 1.0 and cannot boost).
  private let normalizationEQ = AVAudioUnitEQ(numberOfBands: 0)  // use only globalGain

  // Insert a per-player track mixer so we can automate volume on the audio thread
  private let trackMixer = AVAudioMixerNode()
  /// Cached rampable volume parameter for fades/automation
  private var volumeParam: AUParameter?
  private var paramObserverToken: AUParameterObserverToken?
  /// Captured mixer start sample (from the first non-silent tap callback)
  private var scheduledStartSample: AUEventSampleTime?
  /// One-shot tap guards
  private var startTapInstalled = false
  private var didCaptureStart = false

  private var normalizationCalculator: AudioNormalizationCalculator?

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

      let target = newValue

      if let param = resolveVolumeParam() {
        param.setValue(AUValue(target), originator: nil, atHostTime: mach_absolute_time())
        os_log(
          "🔊 mixer volume set → user=%.3f (param=%.3f) addr=%llu",
          log: SpinPlayer.logger, type: .info, newValue, target, param.address)
        print("🔊 Volume set to user=\(newValue), param=\(target)")
      } else {
        os_log(
          "⚠️ mixer volume set failed (no rampable param)", log: SpinPlayer.logger, type: .error)
        print("⚠️ Volume set failed (no rampable param), attempted user=\(newValue)")
      }
    }
  }

  static let shared = SpinPlayer()

  // Class to represent a fade operation
  private class FadeOperation: Hashable {
    let id = UUID()  // Unique identifier for Set operations
    let startVolume: Float
    let endVolume: Float
    let startTime: CFTimeInterval
    let endTime: CFTimeInterval
    let completionBlock: (() -> Void)?

    init(
      startVolume: Float,
      endVolume: Float,
      startTime: CFTimeInterval,
      endTime: CFTimeInterval,
      completionBlock: (() -> Void)?
    ) {
      self.startVolume = startVolume
      self.endVolume = endVolume
      self.startTime = startTime
      self.endTime = endTime
      self.completionBlock = completionBlock
    }

    // Required for Hashable conformance
    static func == (lhs: FadeOperation, rhs: FadeOperation) -> Bool {
      return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(id)
    }

    // Calculate current volume based on elapsed time
    func currentVolume(at currentTime: CFTimeInterval) -> Float {
      let progress = min(1.0, (currentTime - startTime) / (endTime - startTime))
      return startVolume + (endVolume - startVolume) * Float(progress)
    }

    // Check if fade is complete
    func isComplete(at currentTime: CFTimeInterval) -> Bool {
      return currentTime >= endTime
    }
  }

  // MARK: Lifecycle
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
    engine.attach(normalizationEQ)
    engine.attach(trackMixer)

    // Graph: playerNode -> normalizationEQ (globalGain) -> per-track mixer -> main mixer
    engine.connect(
      playerNode,
      to: normalizationEQ,
      format: TapProperties.default.format
    )
    engine.connect(
      normalizationEQ,
      to: trackMixer,
      format: TapProperties.default.format
    )
    engine.connect(
      trackMixer,
      to: playolaMainMixer.mixerNode,
      format: TapProperties.default.format
    )

    // Baselines
    normalizationEQ.globalGain = 0.0  // dB; set per-file on load when normalization is applied
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

  // MARK: Playback

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
    if !engine.isRunning {
      do {
        // Make sure audio session is configured before starting engine
        playolaMainMixer.configureAudioSession()
        try engine.start()
      } catch {
        Task {
          await errorReporter.reportError(
            error,
            context: "Failed to start engine during stop operation",
            level: .error
          )
        }
        return
      }
    }
    playerNode.stop()
    playerNode.reset()
  }

  private func clear() {
    os_log(
      "Clearing SpinPlayer - ID: %@",
      log: SpinPlayer.logger,
      type: .debug,
      self.id.uuidString
    )

    stopAudio()
    clearTimers()
    clearFades()
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

    // Invalidate and clear all fade timers atomically
    if !fadeTimers.isEmpty {
      os_log(
        "Invalidating %d fade timers",
        log: SpinPlayer.logger,
        type: .debug,
        fadeTimers.count
      )
      let timersToInvalidate = fadeTimers
      fadeTimers.removeAll()
      timersToInvalidate.forEach { $0.invalidate() }
    }
  }

  func clearFades() {
    #if os(iOS)
      activeDisplayLink?.invalidate()
      activeDisplayLink = nil
    #else
      fadeUpdateTimer?.invalidate()
      fadeUpdateTimer = nil
    #endif
    activeFades.removeAll()
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
  public func playNow(from: Double, to: Double? = nil) {
    do {
      os_log(
        "Starting playback from position %f",
        log: SpinPlayer.logger,
        type: .info,
        from
      )
      // Record that we're starting mid-file so fades can be shifted appropriately
      self.playbackStartOffset = from
      // Make sure audio session is configured before playback
      playolaMainMixer.configureAudioSession()
      try engine.start()

      // Check if file is still available (not cleared by stop())
      guard let audioFile = currentFile else {
        os_log(
          "Cannot play - audio file was cleared (likely by stop())",
          log: SpinPlayer.logger,
          type: .info
        )
        self.state = .available
        return
      }

      // calculate segment info
      let sampleRate = playerNode.outputFormat(forBus: 0).sampleRate
      let newSampleTime = AVAudioFramePosition(sampleRate * from)
      let framesToPlay = AVAudioFrameCount(Float(sampleRate) * Float(duration))

      // stop the player, schedule the segment, restart the player
      // Volume is already set before playNow is called
      playerNode.stop()
      playerNode.scheduleSegment(
        audioFile,
        startingFrame: newSampleTime,
        frameCount: framesToPlay,
        at: nil,
        completionHandler: nil
      )
      playerNode.play()

      self.state = .playing
      if let spin {
        delegate?.player(self, startedPlaying: spin)
      }
      os_log(
        "Successfully started playback",
        log: SpinPlayer.logger,
        type: .info
      )
    } catch {
      Task {
        await errorReporter.reportError(
          error,
          context: "Failed to start playback at position \(from)s",
          level: .error
        )
      }
      self.state = .available
    }
  }

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

      // Determine what to do based on the spin's timing state
      switch spin.playbackTiming {
      case .future:
        // Spin is in the future - schedule it
        self.volume = spin.startingVolume
        self.schedulePlay(at: spin.airtime)

      case .playing:
        // Spin should be currently playing - start from current position
        let currentDate = spin.dateProvider.now()
        self.volume = spin.volumeAtDate(currentDate)

        let currentTimeInSeconds = currentDate.timeIntervalSince(spin.airtime)
        self.playNow(from: currentTimeInSeconds)

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

  /// Install a one-shot tap to capture the first non-silent render on `trackMixer`,
  /// establishing `scheduledStartSample` so fades can be scheduled in the audio sample domain.
  private func installStartTapIfNeeded(pendingFades: [(offset: Double, to: Float)]) {
    guard !startTapInstalled else { return }
    startTapInstalled = true
    // Ensure engine is running before installing the tap (some devices are picky)
    if !engine.isRunning {
      do {
        playolaMainMixer.configureAudioSession()
        try engine.start()
      } catch {
        os_log(
          "⚠️ Could not start engine before installing tap: %{public}@",
          log: SpinPlayer.logger, type: .error, String(describing: error))
      }
    }
    didCaptureStart = false

    trackMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
      guard let self = self else { return }
      if self.didCaptureStart { return }

      // Require some energy to avoid preroll silence
      var hasEnergy = false
      if let ch = buffer.floatChannelData?.pointee {
        let frameCount = Int(buffer.frameLength)
        var acc: Float = 0
        if frameCount > 0 {
          for i in 0..<frameCount { acc += ch[i] * ch[i] }
          let rms = sqrt(acc / Float(frameCount))
          hasEnergy = rms > 1e-6
        }
      }
      if !hasEnergy { return }

      self.didCaptureStart = true
      self.scheduledStartSample = AUEventSampleTime(time.sampleTime)

      // Remove the tap immediately (one-shot)
      self.trackMixer.removeTap(onBus: 0)
      self.startTapInstalled = false

      // Ensure a known baseline on the exact host time of first render (user-space only)
      if let param = self.resolveVolumeParam() {
        let userInitial = self.spin?.startingVolume ?? self.currentVolume
        let paramInitial = userInitial
        param.setValue(AUValue(paramInitial), originator: nil, atHostTime: time.hostTime)
        os_log(
          "🔧 Baseline mixer volume at start → user=%.3f (param=%.3f) addr=%llu host=%llu",
          log: SpinPlayer.logger, type: .info,
          userInitial, paramInitial, param.address, time.hostTime)
      }

      // Schedule any fades that were waiting for start capture
      self.scheduleFadesAtStartIfNeeded(pendingFades)
    }
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
    let userStart = spin?.startingVolume ?? currentVolume
    var fromParam = userStart

    for (offset, targetUser) in fades {
      let toParam = targetUser
      var when = start + AUEventSampleTime(offset * sr)
      if let rt = trackMixer.lastRenderTime {
        let nowSample = AUEventSampleTime(rt.sampleTime)
        let guardFrames = AUEventSampleTime(sr * 0.010)
        if when <= nowSample + guardFrames { when = nowSample + guardFrames }
      }

      let duration: Double = 1.5
      let steps = 48
      let totalFrames = AUEventSampleTime(duration * sr)
      let framesPerStep = max<AUEventSampleTime>(1, totalFrames / AUEventSampleTime(steps))

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

  private func avAudioTimeFromDate(date: Date) -> AVAudioTime {
    let outputFormat = playerNode.outputFormat(forBus: 0)
    guard let lastRenderTime = playerNode.lastRenderTime else {
      // Handle missing render time
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
      // Fallback to a reasonable default
      return AVAudioTime(sampleTime: 0, atRate: outputFormat.sampleRate)
    }

    let now = lastRenderTime.sampleTime
    let secsUntilDate = date.timeIntervalSinceNow
    return AVAudioTime(
      sampleTime: now + Int64(secsUntilDate * outputFormat.sampleRate),
      atRate: outputFormat.sampleRate
    )
  }

  /// schedule a future play from the beginning of the file
  /// Schedule playback to start at a specific time
  public func schedulePlay(at scheduledDate: Date) {
    do {
      try prepareAudioEngine(scheduledDate: scheduledDate)
      try validateAudioFile()

      // Scheduled plays always start from the top of the file
      self.playbackStartOffset = 0

      let avAudiotime = avAudioTimeFromDate(date: scheduledDate)
      let scheduledSpinId = spin?.id

      playerNode.play(at: avAudiotime)
      setupNotificationTimer(scheduledDate: scheduledDate, scheduledSpinId: scheduledSpinId)

      logScheduleComplete(scheduledDate: scheduledDate)
    } catch {
      reportScheduleError(error)
    }
  }

  private func prepareAudioEngine(scheduledDate: Date) throws {
    os_log(
      "Scheduling play at %@",
      log: SpinPlayer.logger,
      type: .info,
      ISO8601DateFormatter().string(from: scheduledDate)
    )

    playolaMainMixer.configureAudioSession()
    try engine.start()
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

  // MARK: File Loading

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
    if fileSize < 10 * 1024 {
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
      normalizationCalculator = await AudioNormalizationCalculator.create(currentFile!)
      // Derive a per-file gain in dB from the calculator's mapping at unity (1.0)
      // If adjustedVolume(1.0) = k, then gain(dB) = 20 * log10(k)
      let k = Double(self.normalizationCalculator?.adjustedVolume(1.0) ?? 1.0)
      var gainDb = 20.0 * log10(max(1e-6, k))
      // Clamp to AVAudioUnitEQ globalGain limits (−96…+24 dB), we use a tighter practical range
      if gainDb > 24.0 { gainDb = 24.0 }
      if gainDb < -24.0 { gainDb = -24.0 }
      self.normalizationEQ.globalGain = Float(gainDb)
      os_log(
        "🎚️ Set normalizationEQ.globalGain = %.2f dB (scalar k=%.3f) for %@",
        log: SpinPlayer.logger, type: .info,
        gainDb, k, url.lastPathComponent
      )
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

  fileprivate func fadePlayer(
    toVolume endVolume: Float,
    overTime time: Float,
    completionBlock: (() -> Void)? = nil
  ) {
    // Current volume (properly normalized via getter)
    let startVolume = self.volume

    // Current time and end time
    let startTime = CACurrentMediaTime()
    let endTime = startTime + Double(time)

    // Create a new fade operation
    let fadeOperation = FadeOperation(
      startVolume: startVolume,
      endVolume: endVolume,
      startTime: startTime,
      endTime: endTime,
      completionBlock: completionBlock
    )

    // Add to active fades
    activeFades.insert(fadeOperation)

    os_log(
      "Scheduled fade: %.2f→%.2f over %.2fs",
      log: SpinPlayer.logger,
      type: .debug,
      startVolume,
      endVolume,
      time
    )

    #if os(iOS)
      if activeDisplayLink == nil {
        activeDisplayLink = CADisplayLink(
          target: self,
          selector: #selector(updateFades)
        )
        activeDisplayLink?.add(to: .current, forMode: .common)
      }
    #else
      if fadeUpdateTimer == nil {
        fadeUpdateTimer = Timer.scheduledTimer(
          timeInterval: 1.0 / 60.0,
          target: self,
          selector: #selector(updateFades),
          userInfo: nil,
          repeats: true
        )
      }
    #endif

  }

  @objc private func updateFades(_ sender: Any) {
    // Current time
    let currentTime = CACurrentMediaTime()

    // Set containing completed fades to remove
    var completedFades: Set<FadeOperation> = []

    // Track latest volume (for fades that might overlap)
    var latestVolume: Float?

    // Sort the fades by end time (latest fade takes precedence)
    let sortedFades = activeFades.sorted { $0.endTime < $1.endTime }

    // Process each fade
    for fade in sortedFades {
      // If fade is complete, mark for removal and call completion block
      if fade.isComplete(at: currentTime) {
        completedFades.insert(fade)
        fade.completionBlock?()

        // Latest volume is the target volume of the completed fade
        latestVolume = fade.endVolume
      } else {
        // Calculate current volume for this fade
        latestVolume = fade.currentVolume(at: currentTime)
      }
    }

    // Apply the latest calculated volume if any
    if let volume = latestVolume {
      self.volume = volume
    }

    // Remove completed fades
    activeFades.subtract(completedFades)

    if activeFades.isEmpty {
      #if os(iOS)
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
      #else
        fadeUpdateTimer?.invalidate()
        fadeUpdateTimer = nil
      #endif

      os_log("All fades completed", log: SpinPlayer.logger, type: .debug)
    }
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

  private func setClearTimer(_ spin: Spin?) {
    guard let endtime = spin?.endtime else {
      self.clearTimer?.invalidate()
      return
    }

    // for now, fire a timer. Later we should try and use a callback
    self.clearTimer = Timer(
      fire: endtime.addingTimeInterval(1),
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

          self.stopAudio()
          self.clear()
        }
      }
    )
    RunLoop.main.add(self.clearTimer!, forMode: .default)
  }
}

// swiftlint:enable file_length
