// swiftlint:disable file_length function_body_length type_body_length
//
//  AudioPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//

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
/// - Volume fading and crossfading (host-time, sample-accurate)
/// - Audio normalization (baseline gain on EQ)
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
  public var fadeTimers = Set<Timer>()  // still used to trigger *when* to start a fade;
  // the fade itself is scheduled in host time
  private var gainMonitorTimer: Timer?
  private var lastLoggedVolume: Float = 0.0

  /// Track the current baseline volume set via parameter automation
  private var currentBaselineVolume: Float = 1.0

  /// Store when this spin started playing in sample time (playerNode rate - 48kHz)
  private var spinStartSampleTime: AUEventSampleTime?

  /// Store when this spin started playing in mixer sample time (mixer rate - 44.1kHz)
  private var spinStartMixerSampleTime: AUEventSampleTime?

  // deps
  @objc var playolaMainMixer: PlayolaMainMixer = .shared
  private var fileDownloadManager: FileDownloadManaging
  private let errorReporter = PlayolaErrorReporter.shared

  public var localUrl: URL? {
    return self.currentFile?.url
  }

  private var activeDownloadId: UUID?
  public weak var delegate: SpinPlayerDelegate?

  public var duration: Double {
    guard let currentFile else { return 0 }
    let audioNodeFileLength = AVAudioFrameCount(currentFile.length)
    return Double(Double(audioNodeFileLength) / 44100)
  }

  public var state: SpinPlayer.State = .available {
    didSet { delegate?.player(self, didChangeState: state) }
  }

  /// Engine & nodes
  private let engine: AVAudioEngine! = PlayolaMainMixer.shared.engine
  private let playerNode = AVAudioPlayerNode()

  /// Normalization mixer - set once per spin based on audio analysis + starting volume
  private let audioNormalizationMixerNode = AVAudioMixerNode()

  /// Fade mixer - handles dynamic fades via parameter automation
  private let trackMixer = AVAudioMixerNode()

  private var normalizationCalculator: AudioNormalizationCalculator?

  /// The currently playing audio file
  private var currentFile: AVAudioFile? {
    didSet {
      if let file = currentFile {
        loadFile(file)
      }
    }
  }

  public var isPlaying: Bool { playerNode.isPlaying }

  /// Keep node volume simple & stable. Normalization and fades occur on the EQ.
  public var volume: Float {
    get { playerNode.volume }
    set { playerNode.volume = newValue }
  }

  static let shared = SpinPlayer()

  private func mixerNow() -> (now: AUEventSampleTime, sr: Double)? {
    guard engine.isRunning, let rt = trackMixer.lastRenderTime else { return nil }
    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
    return (AUEventSampleTime(rt.sampleTime), sr)
  }

  private func findMixerVolumeParam() -> AUParameter? {
    guard let tree = trackMixer.auAudioUnit.parameterTree else { return nil }
    // Prefer Apple’s “volume” id when present, else the rampable “0” we saw in logs
    return tree.allParameters.first(where: {
      $0.identifier.lowercased() == "volume" && $0.flags.contains(.flag_CanRamp)
    })
      ?? tree.allParameters.first(where: {
        $0.identifier == "0" && $0.flags.contains(.flag_CanRamp)
      })
  }

  private func sanityFadeDownUp() {
    guard engine.isRunning,
      let lastRT = trackMixer.lastRenderTime,
      let param = findMixerVolumeParam()
    else { return }

    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock
    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
    let now = AUEventSampleTime(lastRT.sampleTime)

    // Down to 0 over 0.5s starting in 0.5s
    schedule(
      now + AUEventSampleTime(0.5 * sr),
      AUAudioFrameCount(0.5 * sr),
      param.address,
      0.0)

    // Back to 1.0 over 0.5s starting 1.5s from now
    schedule(
      now + AUEventSampleTime(1.5 * sr),
      AUAudioFrameCount(0.5 * sr),
      param.address,
      1.0)
  }

  // MARK: Lifecycle
  init(
    delegate: SpinPlayerDelegate? = nil,
    fileDownloadManager: FileDownloadManaging? = nil
  ) {
    self.fileDownloadManager = fileDownloadManager ?? FileDownloadManagerAsync.shared
    self.delegate = delegate

    // Centralized audio session config
    playolaMainMixer.configureAudioSession()

    // Graph: player -> audioNormalizationMixerNode -> trackMixer -> main mixer
    engine.attach(playerNode)
    engine.attach(audioNormalizationMixerNode)
    engine.attach(trackMixer)

    engine.connect(
      playerNode,
      to: audioNormalizationMixerNode,
      format: TapProperties.default.format
    )
    engine.connect(
      audioNormalizationMixerNode,
      to: trackMixer,
      format: TapProperties.default.format
    )
    engine.connect(
      trackMixer,
      to: playolaMainMixer.mixerNode,
      format: TapProperties.default.format
    )

    engine.prepare()
  }

  deinit {
    if let activeDownloadId = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: activeDownloadId)
    }
  }

  // MARK: Playback

  public func stop() {
    os_log(
      "🛑 SpinPlayer.stop() called - ID: %@, spin: %@",
      log: SpinPlayer.logger, type: .info,
      self.id.uuidString, self.spin?.id ?? "nil")

    if let activeDownloadId = activeDownloadId {
      os_log(
        "Cancelling download ID: %@ for spin: %@",
        log: SpinPlayer.logger, type: .info,
        activeDownloadId.uuidString, self.spin?.id ?? "nil")
      _ = fileDownloadManager.cancelDownload(id: activeDownloadId)
      self.activeDownloadId = nil
    }

    clear()
  }

  private func stopAudio() {
    if !engine.isRunning {
      do {
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
    os_log("Clearing SpinPlayer - ID: %@", log: SpinPlayer.logger, type: .debug, self.id.uuidString)

    stopAudio()
    clearTimers()  // This will also stop gain monitoring

    self.spin = nil
    self.currentFile = nil
    self.state = .available

    // Reset volumes to neutral
    self.volume = 1.0
    audioNormalizationMixerNode.outputVolume = 1.0
    trackMixer.outputVolume = 1.0
  }

  func clearTimers() {
    os_log(
      "Clearing timers for SpinPlayer - ID: %@", log: SpinPlayer.logger, type: .debug,
      self.id.uuidString)

    if let timer = startNotificationTimer {
      timer.invalidate()
      startNotificationTimer = nil
    }
    if let timer = clearTimer {
      timer.invalidate()
      clearTimer = nil
    }
    if !fadeTimers.isEmpty {
      let timers = fadeTimers
      fadeTimers.removeAll()
      timers.forEach { $0.invalidate() }
    }
    if let timer = gainMonitorTimer {
      timer.invalidate()
      gainMonitorTimer = nil
    }
  }

  private func startGainMonitoring() {
    stopGainMonitoring()

    // Initialize with current baseline volume
    if let tree = trackMixer.auAudioUnit.parameterTree,
      let p = findMixerVolumeParam()
    {
      lastLoggedVolume = p.value
    } else {
      lastLoggedVolume = currentBaselineVolume
    }
    os_log(
      "🎚️ VOLUME MONITOR: Starting - initial volume %.3f linear",
      log: SpinPlayer.logger, type: .info, lastLoggedVolume)

    gainMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      let currentVolume: Float = {

        if let tree = self.trackMixer.auAudioUnit.parameterTree,
          let p = self.findMixerVolumeParam()
        {
          return p.value  // reflects scheduled automation
        }
        return self.trackMixer.outputVolume
      }()

      if abs(currentVolume - self.lastLoggedVolume) > 0.01 {  // Log if change > 0.01 linear
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss.SS"
        let currentTime = timeFormatter.string(from: Date())

        let normalizationVolume = self.audioNormalizationMixerNode.outputVolume
        let effectiveVolume = normalizationVolume * currentVolume

        os_log(
          "🎚️ VOLUME CHANGED: trackMixer %.3f -> %.3f (Δ%.3f), normalization %.3f, effective %.3f at %@",
          log: SpinPlayer.logger, type: .info,
          self.lastLoggedVolume, currentVolume, currentVolume - self.lastLoggedVolume,
          normalizationVolume, effectiveVolume, currentTime)
        self.lastLoggedVolume = currentVolume
      }
    }
  }

  private func stopGainMonitoring() {
    gainMonitorTimer?.invalidate()
    gainMonitorTimer = nil
    os_log("🎚️ VOLUME MONITOR: Stopped", log: SpinPlayer.logger, type: .info)
  }

  private func testParameterAutomation() {
    guard engine.isRunning,
      let lastRT = engine.outputNode.lastRenderTime ?? trackMixer.lastRenderTime,
      let tree = trackMixer.auAudioUnit.parameterTree
    else {
      os_log("🎚️ TEST FADE: Cannot test - engine not ready", log: SpinPlayer.logger, type: .info)
      return
    }

    os_log(
      "🎚️ TEST FADE: Engine running=true, lastRT=%lld, paramTree has %d params",
      log: SpinPlayer.logger, type: .info, lastRT.sampleTime, tree.allParameters.count)

    let param: AUParameter =
      tree.allParameters.first(where: { $0.identifier == "globalGain" })
      ?? tree.allParameters.first(where: { $0.identifier.localizedCaseInsensitiveContains("gain") })
      ?? tree.allParameters.first!

    os_log(
      "🎚️ TEST FADE: Using param '%@' (address=%llu, canRamp=%@)",
      log: SpinPlayer.logger, type: .info,
      param.identifier, param.address, param.flags.contains(.flag_CanRamp) ? "YES" : "NO")

    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock
    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate

    let currentVolume = currentBaselineVolume
    let testVolume = min(1.0, currentVolume + 0.3)  // Increase by 0.3 linear

    os_log(
      "🎚️ TEST FADE: Scheduling test fade from %.3f to %.3f linear in 2 seconds",
      log: SpinPlayer.logger, type: .info, currentVolume, testVolume)

    let nowSamples = AUEventSampleTime(lastRT.sampleTime)
    let startSamples = nowSamples + AUEventSampleTime(sr * 2.0)  // 2 seconds delay
    let rampFrames = AUAudioFrameCount(sr * 1.0)  // 1 second ramp

    os_log(
      "🎚️ TEST FADE: nowSamples=%lld, startSamples=%lld, rampFrames=%d",
      log: SpinPlayer.logger, type: .info, nowSamples, startSamples, rampFrames)

    schedule(startSamples, rampFrames, param.address, AUValue(testVolume))
  }

  /// Plays the loaded spin immediately from the specified position.
  public func playNow(from: Double, to: Double? = nil) {
    do {
      os_log("Starting playback from position %f", log: SpinPlayer.logger, type: .info, from)

      playolaMainMixer.configureAudioSession()
      try engine.start()

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        self.trackMixer.outputVolume = 0.0  // should go silent right now
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.trackMixer.outputVolume = 1.0  // should return to normal
      }

      dumpEngineClock("after engine.start() / playNow")

      guard let audioFile = currentFile else {
        os_log(
          "Cannot play - audio file was cleared (likely by stop())",
          log: SpinPlayer.logger, type: .info)
        self.state = .available
        return
      }

      let sampleRate = playerNode.outputFormat(forBus: 0).sampleRate
      let newSampleTime = AVAudioFramePosition(sampleRate * from)
      let framesToPlay = AVAudioFrameCount(Float(sampleRate) * Float(duration))

      // Keep node volume steady; dynamic gain is on EQ
      self.volume = 1.0

      playerNode.stop()
      playerNode.scheduleSegment(
        audioFile,
        startingFrame: newSampleTime,
        frameCount: framesToPlay,
        at: nil,
        completionHandler: nil
      )
      playerNode.play()
      //      sanityFadeDownUp()
      dumpEngineClock("after playerNode.play()")

      // Store the start sample time for fade calculations using mixer's time domain
      if let mixerRT = trackMixer.lastRenderTime {
        spinStartMixerSampleTime = mixerRT.sampleTime
        let mixerSR = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
        os_log(
          "🎯 SPIN START: Stored mixer start sample time %lld (%.0fkHz)", log: SpinPlayer.logger,
          type: .info, mixerRT.sampleTime, mixerSR / 1000)
      }

      self.state = .playing
      if let spin { delegate?.player(self, startedPlaying: spin) }

      // Start monitoring gain changes
      startGainMonitoring()

      os_log("Successfully started playback", log: SpinPlayer.logger, type: .info)
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

  /// Loads a spin, prepares it for playback, schedules play & fades.
  public func load(_ spin: Spin, onDownloadProgress: ((Float) -> Void)? = nil)
    async -> Result<URL, Error>
  {
    os_log("Loading spin: %@", log: SpinPlayer.logger, type: .info, spin.id)

    // Log the spin's fade information
    if spin.fades.isEmpty {
      os_log(
        "🎚️ SPIN LOADED: '%@' has no fades",
        log: SpinPlayer.logger, type: .info, spin.audioBlock.title)
    } else {
      os_log(
        "🎚️ SPIN LOADED: '%@' has %d fades:",
        log: SpinPlayer.logger, type: .info, spin.audioBlock.title, spin.fades.count)
      for (index, fade) in spin.fades.enumerated() {
        os_log(
          "🎚️   FADE %d: at %dms to volume %.1f",
          log: SpinPlayer.logger, type: .info,
          index + 1, fade.atMS, fade.toVolume)
      }
    }

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
      await errorReporter.reportError(error, context: "Missing download URL", level: .error)
    }
    self.state = .available
    return error
  }

  private func cancelActiveDownload() {
    if let id = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: id)
      activeDownloadId = nil
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

      if spin.isPlaying {
        let currentTimeInSeconds = Date().timeIntervalSince(spin.airtime)
        self.playNow(from: currentTimeInSeconds)
        self.volume = 1.0
        // Schedule fades immediately for currently playing spins
        self.scheduleFades(spin)
      } else {
        self.schedulePlay(at: spin.airtime)
        dumpEngineClock("after engine.start() / schedulePlay")
        self.volume = 1.0  // node stays at unity; starting loudness is EQ baseline
        // Fades will be scheduled when timer fires and we have actual start time
      }
      self.state = .loaded
      continuation.resume(returning: .success(localUrl))
    }
  }

  private func handleFailedDownload(
    error: FileDownloadError,
    continuation: CheckedContinuation<Result<URL, Error>, Never>
  ) {
    Task { @MainActor in
      await self.errorReporter.reportError(error, context: "Download failed", level: .error)
    }
    self.state = .available
    continuation.resume(returning: .failure(error))
  }

  // Convert a wall-clock date to AVAudioTime relative to engine render time
  private func avAudioTimeFromDate(date: Date) -> AVAudioTime {
    let outputFormat = playerNode.outputFormat(forBus: 0)
    guard let lastRenderTime = playerNode.lastRenderTime else {
      let error = NSError(
        domain: "fm.playola.PlayolaPlayer",
        code: 500,
        userInfo: [NSLocalizedDescriptionKey: "Could not get last render time from player node"]
      )
      Task {
        await errorReporter.reportError(error, context: "Missing render time", level: .warning)
      }
      return AVAudioTime(sampleTime: 0, atRate: outputFormat.sampleRate)
    }

    let nowSamples = lastRenderTime.sampleTime
    let secsUntilDate = date.timeIntervalSinceNow
    return AVAudioTime(
      sampleTime: nowSamples + Int64(secsUntilDate * outputFormat.sampleRate),
      atRate: outputFormat.sampleRate
    )
  }

  /// Schedule playback to start at a specific wall-clock time.
  public func schedulePlay(at scheduledDate: Date) {
    do {
      try prepareAudioEngine(scheduledDate: scheduledDate)
      try validateAudioFile()

      let avTime = avAudioTimeFromDate(date: scheduledDate)
      let scheduledSpinId = spin?.id

      playerNode.play(at: avTime)

      // Store the start sample time immediately when scheduling in mixer's time domain
      let mixerSR = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
      let outputNodeSR = engine.outputNode.outputFormat(forBus: 0).sampleRate
      let ratio = mixerSR / outputNodeSR
      let convertedSample = Double(avTime.sampleTime) * ratio
      spinStartMixerSampleTime = nil

      os_log(
        "🎯 SAMPLE CONVERSION DEBUG: input=%lld, mixerSR=%.1f, outputSR=%.1f, ratio=%.6f, converted=%.1f, result=%lld",
        log: SpinPlayer.logger, type: .info,
        avTime.sampleTime, mixerSR, outputNodeSR, ratio, convertedSample,
        spinStartMixerSampleTime ?? 0)

      os_log(
        "🎯 SPIN SCHEDULED: Converted start sample time %lld (%.0fkHz) -> %lld (%.0fkHz)",
        log: SpinPlayer.logger, type: .info, avTime.sampleTime, outputNodeSR / 1000,
        spinStartMixerSampleTime ?? 0, mixerSR / 1000)
      setupNotificationTimer(scheduledDate: scheduledDate, scheduledSpinId: scheduledSpinId)

      logScheduleComplete(scheduledDate: scheduledDate)
    } catch {
      reportScheduleError(error)
    }
  }

  private func prepareAudioEngine(scheduledDate: Date) throws {
    os_log(
      "Scheduling play at %@", log: SpinPlayer.logger, type: .info,
      ISO8601DateFormatter().string(from: scheduledDate))
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
          level: .error)
      }
      throw error
    }
  }

  private func setupNotificationTimer(scheduledDate: Date, scheduledSpinId: String?) {
    self.startNotificationTimer = Timer(fire: scheduledDate, interval: 0, repeats: false) {
      [weak self] timer in
      timer.invalidate()
      os_log("⏰ Timer fired", log: SpinPlayer.logger, type: .info)
      guard let self = self else { return }
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
    dumpEngineClock("timer fired (about to be rendering)")
    os_log("✅ Timer fired successfully", log: SpinPlayer.logger, type: .info)
    self.startNotificationTimer = nil

    // Only set spinStartMixerSampleTime if we DON'T already have the value
    // captured at schedulePlay (converted from avTime). This avoids shifting
    // all fade offsets later by however many frames have elapsed since start.
    if spinStartMixerSampleTime == nil, let mixerRT = trackMixer.lastRenderTime {
      spinStartMixerSampleTime = mixerRT.sampleTime
      let mixerSR = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
      os_log(
        "🎯 SPIN START: captured mixer start sample at timer fire: %lld (%.0fkHz)",
        log: SpinPlayer.logger, type: .info, mixerRT.sampleTime, mixerSR / 1000)
    } else if let mixerRT = trackMixer.lastRenderTime, let start = spinStartMixerSampleTime {
      let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
      let deltaFrames = mixerRT.sampleTime - start
      let deltaMs = (Double(deltaFrames) / sr) * 1000.0
      os_log(
        "🧭 START CHECK: now=%lld, storedStart=%lld, Δ=%.1fms",
        log: SpinPlayer.logger, type: .info, mixerRT.sampleTime, start, deltaMs)
    }

    // (Optional) Keep this output-node sample time for other debugging, but it's not
    // used for fade math.
    if let lastRT = engine.outputNode.lastRenderTime ?? trackMixer.lastRenderTime {
      spinStartSampleTime = lastRT.sampleTime
      os_log(
        "🎯 SPIN START: output sample time snapshot %lld",
        log: SpinPlayer.logger, type: .info, lastRT.sampleTime)
    }

    // Schedule fades now that the start sample is known
    scheduleFades(spin)

    self.state = .playing
    startGainMonitoring()
    self.delegate?.player(self, startedPlaying: spin)
  }

  private func logScheduleComplete(scheduledDate: Date) {
    os_log(
      "Added timer to RunLoop for spin: %@ scheduled at %@",
      log: SpinPlayer.logger, type: .debug,
      self.spin?.id ?? "nil",
      ISO8601DateFormatter().string(from: scheduledDate))
  }

  private func reportScheduleError(_ error: Error) {
    Task {
      await errorReporter.reportError(error, context: "Failed to schedule playback", level: .error)
    }
  }

  // MARK: File Loading

  /// Loads an AVAudioFile into the current player node
  private func loadFile(_ file: AVAudioFile) {
    playerNode.scheduleFile(file, at: nil)
  }

  public func loadFile(with url: URL) async {
    os_log("Loading audio file: %@", log: SpinPlayer.logger, type: .info, url.lastPathComponent)

    do {
      let fileSize = try validateFileExistsAndGetSize(url)
      try await createAudioFileFromValidatedURL(url, fileSize: fileSize)
    } catch {
      await handleFileLoadError(error)
    }
  }

  private func validateFileExistsAndGetSize(_ url: URL) throws -> Int {
    let fm = FileManager.default

    guard fm.fileExists(atPath: url.path) else {
      let error = FileDownloadError.fileNotFound(url.path)
      Task {
        await errorReporter.reportError(
          error, context: "Audio file not found at path", level: .error)
      }
      self.state = .available
      throw error
    }

    let attributes = try fm.attributesOfItem(atPath: url.path)
    let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0

    try validateFileSize(fileSize, url: url, fileManager: fm)
    return fileSize
  }

  private func validateFileSize(_ fileSize: Int, url: URL, fileManager: FileManager) throws {
    if fileSize < 10 * 1024 {
      let error = FileDownloadError.downloadFailed("Audio file is too small: \(fileSize) bytes")
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
      applyNormalizationBaseline()  // <- set EQ baseline once we have amplitude
      logSuccessfulLoad(url)
    } catch let audioError as NSError {
      await handleAudioFileCreationError(audioError, url: url, fileSize: fileSize)
      throw audioError
    }
  }

  private func logSuccessfulLoad(_ url: URL) {
    os_log(
      "Successfully loaded audio file: %@", log: SpinPlayer.logger, type: .info,
      url.lastPathComponent)
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
    let fm = FileManager.default
    switch audioError.code {
    case 1_954_115_647:  // 'fmt?'
      Task {
        await errorReporter.reportError(
          audioError,
          context: "\(contextInfo) - Invalid audio format or corrupt file",
          level: .error)
      }
      try? fm.removeItem(at: url)
    default:
      await reportAudioError(audioError, contextInfo: contextInfo)
    }
  }

  private func reportAudioError(_ audioError: NSError, contextInfo: String) async {
    Task {
      await errorReporter.reportError(audioError, context: contextInfo, level: .error)
    }
  }

  private func handleFileLoadError(_ error: Error) async {
    let shouldReport =
      !error.localizedDescription.contains("too small")
      && !error.localizedDescription.contains("not found")
    if shouldReport {
      Task {
        await errorReporter.reportError(error, context: "File validation failed", level: .error)
      }
    }
    self.state = .available
  }

  // MARK: Fades (sample-accurate AU parameter ramps on mixer volume)

  /// Public API to schedule a fade (volume 0..1) over time (seconds).
  /// Internally ramps EQ globalGain in dB at host time; no timers or display links.
  fileprivate func fadePlayer(
    toVolume endVolumeLinear: Float,
    overTime timeSeconds: Float,
    startDelaySeconds: Double = 0,
    completionBlock: (() -> Void)? = nil
  ) {
    let spinTitle = self.spin?.audioBlock.title ?? "Unknown"

    if startDelaySeconds > 0 {
      os_log(
        "🎚️ FADE SCHEDULED: '%@' will fade to volume %.1f in %.1fs (delay: %.1fs)",
        log: SpinPlayer.logger, type: .info,
        spinTitle, endVolumeLinear, timeSeconds, startDelaySeconds)
    } else {
      os_log(
        "🎚️ FADE STARTING: '%@' fading to volume %.1f over %.1fs",
        log: SpinPlayer.logger, type: .info,
        spinTitle, endVolumeLinear, timeSeconds)
    }

    guard engine.isRunning,
      let lastRT = engine.outputNode.lastRenderTime ?? trackMixer.lastRenderTime,
      let tree = trackMixer.auAudioUnit.parameterTree
    else {
      let fadeTarget = max(0, min(1, endVolumeLinear))
      trackMixer.outputVolume = fadeTarget
      os_log(
        "🎚️ FADE IMMEDIATE: '%@' volume set to %.1f",
        log: SpinPlayer.logger, type: .info,
        spinTitle, fadeTarget)
      completionBlock?()
      return
    }

    let currentVolume = trackMixer.outputVolume
    let startParamLinear = currentVolume
    let endParamLinear = max(0, min(1, endVolumeLinear))

    os_log(
      "🎚️ FADE MATH: currentVolume=%.3f, endVolume=%.1f",
      log: SpinPlayer.logger, type: .info,
      currentVolume, endParamLinear)

    let fadeRange = abs(endParamLinear - startParamLinear)
    if fadeRange < 0.05 {
      os_log(
        "🎚️ WARNING: Fade range is very small (%.3f linear) - may not be audible",
        log: SpinPlayer.logger, type: .info, fadeRange)
    }

    // Find the volume parameter to automate
    guard let param = findMixerVolumeParam() else {
      os_log(
        "🎚️ FADE SKIP: No volume parameter found in mixer",
        log: SpinPlayer.logger, type: .error)
      completionBlock?()
      return
    }

    os_log(
      "🎚️ PARAM INFO: Using parameter '%@' (address=%llu, min=%.1f, max=%.1f, current=%.1f)",
      log: SpinPlayer.logger, type: .info,
      param.identifier, param.address, param.minValue, param.maxValue, param.value)

    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock
    let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
    let nowSamples = AUEventSampleTime(lastRT.sampleTime)

    let startSamples = nowSamples + AUEventSampleTime(sr * max(0.0, startDelaySeconds))
    let rampFrames = AUAudioFrameCount(max(0.0, Double(timeSeconds)) * sr)

    // Set the current value immediately (host time is fine here)
    param.setValue(AUValue(startParamLinear), originator: nil, atHostTime: lastRT.hostTime)
    os_log(
      "🎚️ SET IMMEDIATE: Set param to %.3f linear at hostTime",
      log: SpinPlayer.logger, type: .info, startParamLinear)

    // Schedule ramp TO the end value
    schedule(startSamples, rampFrames, param.address, AUValue(endParamLinear))
    os_log(
      "🎚️ SCHEDULED RAMP: From %.3f to %.3f over %d frames starting at sample %lld",
      log: SpinPlayer.logger, type: .info, startParamLinear, endParamLinear, rampFrames,
      startSamples)

    // Log the scheduled parameter change for monitoring
    os_log(
      "🎚️ PARAM SCHEDULED: param address=%llu, startSamples=%lld, rampFrames=%d, startValue=%.3f, endValue=%.3f",
      log: SpinPlayer.logger, type: .info,
      param.address, startSamples, rampFrames, startParamLinear, endParamLinear)

    // Optional completion callback (approx on main)
    if timeSeconds <= 0 {
      os_log(
        "🎚️ FADE COMPLETE: '%@' fade completed immediately",
        log: SpinPlayer.logger, type: .info, spinTitle)
      completionBlock?()
    } else {
      let deadline = DispatchTime.now() + .milliseconds(Int((0.02 + Double(timeSeconds)) * 1000))
      DispatchQueue.main.asyncAfter(deadline: deadline) {
        os_log(
          "🎚️ FADE COMPLETE: '%@' fade to volume %.1f completed",
          log: SpinPlayer.logger, type: .info, spinTitle, endVolumeLinear)
        completionBlock?()
      }
    }
  }

  public func scheduleFades(_ spin: Spin) {
    guard engine.isRunning,
      let rt = trackMixer.lastRenderTime,
      let tree = trackMixer.auAudioUnit.parameterTree,
      let param = findMixerVolumeParam()
    else {
      os_log(
        "🎚️ FADE SKIP: Engine not running, no render time, or no param for '%@'",
        log: SpinPlayer.logger, type: .debug, spin.audioBlock.title)
      return
    }

    guard let startSample = spinStartMixerSampleTime else {
      os_log(
        "🎚️ FADE SKIP: No spin start mixer sample time available for '%@'",
        log: SpinPlayer.logger, type: .error, spin.audioBlock.title)
      return
    }

    if spin.fades.isEmpty {
      os_log(
        "🎚️ NO FADES: '%@' has none", log: SpinPlayer.logger, type: .debug, spin.audioBlock.title)
      return
    }

    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock
    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
    let nowSample = AUEventSampleTime(rt.sampleTime)
    let guardFrames = AUEventSampleTime(sr * 0.010)  // 10ms guard to avoid “now” races
    let rampFrames = AUAudioFrameCount(1.5 * sr)  // 1.5s ramps

    // Debug preamble
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SS"
    os_log(
      "🎚️ SCHEDULING FADES: '%@' (%d fades) startSample=%lld now=%lld sr=%.0f wall=%@",
      log: SpinPlayer.logger, type: .info,
      spin.audioBlock.title, spin.fades.count, startSample, nowSample, sr, df.string(from: Date()))
    os_log(
      "🎚️ USING PARAM: '%@' (addr=%llu, canRamp=%@)",
      log: SpinPlayer.logger, type: .info,
      param.identifier, param.address, param.flags.contains(.flag_CanRamp) ? "YES" : "NO")

    // Build events in mixer sample domain
    struct Ev {
      let index: Int
      let when: AUEventSampleTime
      let target: AUValue
      let atMS: Int
    }
    let events: [Ev] = spin.fades.enumerated().map { (i, f) in
      let off = AUEventSampleTime((Double(f.atMS) / 1000.0) * sr)
      let tgt = AUValue(max(0, min(1, f.toVolume)))
      return Ev(index: i + 1, when: startSample + off, target: tgt, atMS: f.atMS)
    }

    // 1) Catch up to latest past event (if any)
    if let lastPast = events.filter({ $0.when <= nowSample }).max(by: { $0.when < $1.when }) {
      param.setValue(lastPast.target, originator: nil, atHostTime: rt.hostTime)
      let elapsed = (Double(nowSample - startSample) / sr)
      os_log(
        "⏮️ CATCH-UP → set immediate to fade %d target=%.3f at elapsed=%.3fs (req=%lld ≤ now=%lld)",
        log: SpinPlayer.logger, type: .info,
        lastPast.index, lastPast.target, elapsed, lastPast.when, nowSample)
    }

    // 2) Schedule future events (with clamping)
    for ev in events where ev.when > nowSample {
      var start = ev.when
      if start <= nowSample + guardFrames {
        let lateMs = (Double(nowSample - start) / sr) * 1000.0
        os_log(
          "⏱️ FADE %d NEAR/PAST by %.1f ms (req=%lld, now=%lld) → clamp to now+10ms",
          log: SpinPlayer.logger, type: .info,
          ev.index, lateMs, ev.when, nowSample)
        start = nowSample + guardFrames
      }

      let rel = (Double(start - startSample) / sr)
      os_log(
        "🎚️ QUEUE FADE %d: at=%dms (rel=%.3fs from spin start) startSample=%lld target=%.3f",
        log: SpinPlayer.logger, type: .info,
        ev.index, ev.atMS, rel, start, ev.target)

      schedule(start, rampFrames, param.address, ev.target)
    }
  }

  private func setClearTimer(_ spin: Spin?) {
    guard let endtime = spin?.endtime else {
      self.clearTimer?.invalidate()
      return
    }

    self.clearTimer = Timer(
      fire: endtime.addingTimeInterval(1),
      interval: 0,
      repeats: false,
      block: { [weak self] timer in
        timer.invalidate()
        guard let self = self else { return }
        Task { @MainActor in
          guard self.clearTimer === timer else { return }
          self.clearTimer = nil
          self.stopAudio()
          self.clear()
        }
      }
    )
    RunLoop.main.add(self.clearTimer!, forMode: .default)
  }

  // MARK: Normalization baseline

  /// Apply a fixed baseline gain on the normalization mixer from the measured amplitude.
  /// This mixer is set once per spin and never changes during playback.
  private func applyNormalizationBaseline() {
    let baselineDB = baselineGainDB(
      forAmplitude: normalizationCalculator?.amplitude, targetPeak: 0.80)
    let normalizationLinear = pow(10.0, baselineDB / 20.0)  // dB -> linear

    // Set the normalization mixer to just the normalization gain
    audioNormalizationMixerNode.outputVolume = normalizationLinear
    currentBaselineVolume = normalizationLinear

    // Set the track mixer to the spin's starting volume
    let startingVolumeLinear: Float
    if let spin = self.spin {
      startingVolumeLinear = spin.startingVolume
      os_log(
        "🎚️ NORMALIZATION: normalization=%.1f dB (%.3f linear), startingVolume=%.2f linear",
        log: SpinPlayer.logger, type: .info,
        baselineDB, normalizationLinear, startingVolumeLinear)
    } else {
      startingVolumeLinear = 1.0
      os_log(
        "🎚️ NORMALIZATION: normalization only = %.1f dB (%.3f linear)",
        log: SpinPlayer.logger, type: .info, baselineDB, normalizationLinear)
    }

    // Set the track mixer starting volume via parameter automation to avoid conflicts with fades
    if engine.isRunning,
      let lastRT = engine.outputNode.lastRenderTime ?? trackMixer.lastRenderTime,
      let tree = trackMixer.auAudioUnit.parameterTree,
      let param = tree.allParameters.first(where: {
        $0.identifier == "0" && $0.flags.contains(.flag_CanRamp)
      })
    {
      param.setValue(AUValue(startingVolumeLinear), originator: nil, atHostTime: lastRT.hostTime)
      os_log(
        "🎚️ TRACK MIXER: Set starting volume %.3f via parameter automation",
        log: SpinPlayer.logger, type: .info, startingVolumeLinear)
    } else {
      trackMixer.outputVolume = startingVolumeLinear
      os_log(
        "🎚️ TRACK MIXER: Set starting volume %.3f via direct assignment (fallback)",
        log: SpinPlayer.logger, type: .info, startingVolumeLinear)
    }

    os_log(
      "🎚️ MIXER VOLUMES SET: audioNormalizationMixerNode=%.3f, trackMixer=%.3f, effective=%.3f",
      log: SpinPlayer.logger, type: .info, normalizationLinear, startingVolumeLinear,
      normalizationLinear * startingVolumeLinear)
  }

  /// Convert a measured peak amplitude (0..1) into a baseline dB so perceived level is consistent.
  private func baselineGainDB(forAmplitude amp: Float?, targetPeak: Float = 0.8) -> Float {
    guard let ampVal = amp, ampVal > 0 else { return 0.0 }
    let clampedTarget = max(0.000_001, min(1.0, targetPeak))
    let measured = min(max(ampVal, 0.000_001), 1.0)
    let ratio = clampedTarget / measured
    let db = 20.0 * log10f(ratio)
    return clampDB(db, minDB: -24.0, maxDB: 24.0)
  }

  // MARK: Utilities

  private func clampDB(_ db: Float, minDB: Float = -60.0, maxDB: Float = 0.0) -> Float {
    return max(minDB, min(maxDB, db))
  }

  /// Musical/logarithmic mapping for fades. 0..1 linear -> [-60, 0] dB
  private func linearToDecibels(_ valueLinear: Float) -> Float {
    let clamped = max(0.000_001, min(1.0, valueLinear))
    return clampDB(20.0 * log10f(clamped))
  }

  private func dumpEngineClock(_ tag: String) {
    let outFmt = engine.outputNode.outputFormat(forBus: 0)
    let outRT = engine.outputNode.lastRenderTime
    let mixRT = trackMixer.lastRenderTime
    let plyRT = playerNode.lastRenderTime

    func desc(_ t: AVAudioTime?) -> String {
      guard let t else { return "nil" }
      return "host=\(t.hostTime) sample=\(t.sampleTime) rate=\(t.sampleRate)"
    }

    os_log(
      "🧭 CLOCK[%@] isRunning=%{public}@  SR=%.1f",
      log: SpinPlayer.logger, type: .info,
      tag, engine.isRunning ? "YES" : "NO", outFmt.sampleRate)

    os_log(
      "🧭   outputNode.lastRenderTime: %{public}@",
      log: SpinPlayer.logger, type: .info, desc(outRT))
    os_log(
      "🧭   trackMixer.lastRenderTime: %{public}@",
      log: SpinPlayer.logger, type: .info, desc(mixRT))
    os_log(
      "🧭   playerNode.lastRenderTime: %{public}@",
      log: SpinPlayer.logger, type: .info, desc(plyRT))

    os_log(
      "🧭   audioNormalizationMixerNode.outputVolume: %.4f",
      log: SpinPlayer.logger, type: .info, audioNormalizationMixerNode.outputVolume)
    os_log(
      "🧭   trackMixer.outputVolume: %.4f",
      log: SpinPlayer.logger, type: .info, trackMixer.outputVolume)

    if let p = trackMixer.auAudioUnit.parameterTree?
      .allParameters.first(where: { $0.identifier == "0" && $0.flags.contains(.flag_CanRamp) })
    {
      os_log(
        "🧭   trackMixer param('0') value=%.4f (min=%.2f max=%.2f)",
        log: SpinPlayer.logger, type: .info, p.value, p.minValue, p.maxValue)
    } else {
      os_log("🧭   trackMixer param('0') NOT FOUND", log: SpinPlayer.logger, type: .info)
    }
  }
}
