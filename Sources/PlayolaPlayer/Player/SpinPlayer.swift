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
import QuartzCore

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
  private static let logger = OSLog(subsystem: "fm.playola.playolaCore",
                                    category: "Player")

  public var id: UUID = UUID()
  public var spin: Spin? {
    didSet { setClearTimer(spin) }
  }

  public var startNotificationTimer: Timer?
  public var clearTimer: Timer?
  public var fadeTimers = Set<Timer>()

  // Add these properties for the improved fade system
  private var activeDisplayLink: CADisplayLink?
  private var activeFades: Set<FadeOperation> = []

  public var localUrl: URL? { return currentFile?.url }

  // dependencies
  @objc var playolaMainMixer: PlayolaMainMixer = .shared
  private var fileDownloadManager: FileDownloadManaging
  private let errorReporter = PlayolaErrorReporter.shared

  // Track active download ID
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

  /// An internal instance of AVAudioEngine
  private let engine: AVAudioEngine! = PlayolaMainMixer.shared.engine

  /// The node responsible for playing the audio file
  private let playerNode = AVAudioPlayerNode()

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
    get {
      guard let normalizationCalculator else { return playerNode.volume }
      return normalizationCalculator.playerVolume(playerNode.volume)
    }
    set {
      guard let normalizationCalculator else {
        playerNode.volume = newValue
        return
      }
      playerNode.volume = normalizationCalculator.adjustedVolume(newValue)
    }
  }

  static let shared = SpinPlayer()

  // Class to represent a fade operation
  private class FadeOperation: Hashable {
    let id = UUID() // Unique identifier for Set operations
    let startVolume: Float
    let endVolume: Float
    let startTime: CFTimeInterval
    let endTime: CFTimeInterval
    let completionBlock: (() -> ())?

    init(
      startVolume: Float,
      endVolume: Float,
      startTime: CFTimeInterval,
      endTime: CFTimeInterval,
      completionBlock: (() -> ())?
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
  init(delegate: SpinPlayerDelegate? = nil,
       fileDownloadManager: FileDownloadManaging? = nil) {
    self.fileDownloadManager = fileDownloadManager ?? FileDownloadManager.shared
    self.delegate = delegate

    // Use the centralized audio session management instead of configuring here
    playolaMainMixer.configureAudioSession()

    /// Make connections
    engine.attach(playerNode)
    engine.connect(playerNode,
                   to: playolaMainMixer.mixerNode,
                   format: TapProperties.default.format)
    engine.prepare()
  }

  deinit {
    // Cancel any active download
    if let activeDownloadId = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: activeDownloadId)
    }
  }

  // MARK: Playback

  public func stop() {
    // Cancel any active download
    if let activeDownloadId = activeDownloadId {
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
        errorReporter.reportError(error, context: "Failed to start engine during stop operation", level: .error)
        return
      }
    }
    playerNode.stop()
    playerNode.reset()
  }

  private func clear() {
    stopAudio()
    clearTimers()
    clearFades()

    self.spin = nil
    self.currentFile = nil
    self.state = .available
    self.volume = 1.0
  }

  func clearTimers() {
    startNotificationTimer?.invalidate()
    startNotificationTimer = nil
    clearTimer?.invalidate()
    clearTimer = nil
    fadeTimers.forEach { $0.invalidate() }
    fadeTimers.removeAll()
  }

  func clearFades() {
    activeDisplayLink?.invalidate()
    activeDisplayLink = nil
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
      os_log("Starting playback of %@ by %@ (spinID: %@) from position %f",
             log: SpinPlayer.logger, type: .info,
             spin?.audioBlock?.title ?? "unknown",
             spin?.audioBlock?.artist ?? "unknown",
             spin?.id ?? "unknown", from)
      // Make sure audio session is configured before playback
      playolaMainMixer.configureAudioSession()
      try engine.start()

      // calculate segment info
      let sampleRate = playerNode.outputFormat(forBus: 0).sampleRate
      let newSampleTime = AVAudioFramePosition(sampleRate * from)
      let framesToPlay = AVAudioFrameCount(Float(sampleRate) * Float(duration))

      // stop the player, schedule the segment, restart the player
      self.volume = spin?.startingVolume ?? 1.0
      playerNode.stop()
      playerNode.scheduleSegment(currentFile!, startingFrame: newSampleTime, frameCount: framesToPlay, at: nil, completionHandler: nil)
      playerNode.play()

      self.state = .playing
      if let spin {
        delegate?.player(self, startedPlaying: spin)
      }
      os_log("Successfully started playback of %@ (spinID: %@)",
             log: SpinPlayer.logger, type: .info,
             spin?.audioBlock?.title ?? "unknown",
             spin?.id ?? "unknown")
    } catch {
      errorReporter.reportError(error,
                                context: "Failed to start playback at position \(from)s for spin ID: \(spin?.id ?? "unknown")",
                                level: .error)
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
  public func load(_ spin: Spin, onDownloadProgress: ((Float) -> Void)? = nil) async -> Result<URL, Error> {
    self.state = .loading
    self.spin = spin

    os_log("Loading spin: %@ by %@ (spinID: %@)",
           log: SpinPlayer.logger, type: .info,
           spin.audioBlock?.title ?? "unknown",
           spin.audioBlock?.artist ?? "unknown",
           spin.id)

    guard let audioFileUrl = spin.audioBlock?.downloadUrl else {
      let error = NSError(domain: "fm.playola.PlayolaPlayer", code: 400, userInfo: [
        NSLocalizedDescriptionKey: "Invalid audio file URL in spin",
        "spinId": spin.id,
        "audioBlockId": spin.audioBlock?.id ?? "nil",
        "audioBlockTitle": spin.audioBlock?.title ?? "nil"
      ])
      errorReporter.reportError(error,
                                context: "Missing or invalid download URL for spin ID: \(spin.id)",
                                level: .error)
      self.state = .available
      return .failure(error)
    }

    // Cancel any existing download
    if let activeDownloadId = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: activeDownloadId)
      self.activeDownloadId = nil
    }

    do {
      let localUrl = try await fileDownloadManager.downloadFileAsync(
        remoteUrl: audioFileUrl,
        progressHandler: onDownloadProgress
      )

      self.loadFile(with: localUrl)

      if spin.isPlaying {
        let currentTimeInSeconds = Date().timeIntervalSince(spin.airtime)
        self.playNow(from: currentTimeInSeconds)
        self.volume = 1.0
      } else {
        self.schedulePlay(at: spin.airtime)
        self.volume = spin.startingVolume
      }

      self.scheduleFades(spin)
      self.state = .loaded

      return .success(localUrl)
    } catch {
      self.errorReporter.reportError(error,
                                     context: "Failed to download audio file: \(audioFileUrl.lastPathComponent)",
                                     level: .error)
      self.state = .available
      return .failure(error)
    }
  }

  private func avAudioTimeFromDate(date: Date) -> AVAudioTime {
    let outputFormat = playerNode.outputFormat(forBus: 0)
    guard let lastRenderTime = playerNode.lastRenderTime else {
      // Handle missing render time
      let error = NSError(domain: "fm.playola.PlayolaPlayer", code: 500, userInfo: [
        NSLocalizedDescriptionKey: "Could not get last render time from player node"
      ])
      errorReporter.reportError(error, context: "Missing render time", level: .warning)
      // Fallback to a reasonable default
      return AVAudioTime(sampleTime: 0, atRate: outputFormat.sampleRate)
    }

    let now = lastRenderTime.sampleTime
    let secsUntilDate = date.timeIntervalSinceNow
    return AVAudioTime(sampleTime: now + Int64(secsUntilDate * outputFormat.sampleRate), atRate: outputFormat.sampleRate)
  }

  /// schedule a future play from the beginning of the file
  /// Schedule playback to start at a specific time
  public func schedulePlay(at scheduledDate: Date) {
    do {
      os_log("Scheduling play at %@ for %@ by %@ (spinID: %@)",
             log: SpinPlayer.logger, type: .info,
             ISO8601DateFormatter().string(from: scheduledDate),
             spin?.audioBlock?.title ?? "unknown",
             spin?.audioBlock?.artist ?? "unknown",
             spin?.id ?? "unknown")

      // Make sure audio session is configured before scheduling playback
      playolaMainMixer.configureAudioSession()
      try engine.start()

      // Convert the target date to AVAudioTime
      let avAudiotime = avAudioTimeFromDate(date: scheduledDate)

      // If the file isn't loaded yet, we need to schedule it
      guard let currentFile = self.currentFile else {
        let error = NSError(domain: "fm.playola.PlayolaPlayer", code: 400, userInfo: [
          NSLocalizedDescriptionKey: "No audio file loaded when trying to schedule playback"
        ])
        errorReporter.reportError(error, context: "Missing audio file for scheduled playback", level: .error)
        return
      }

      // For safety, capture the current spin ID to verify it later
      let scheduledSpinId = spin?.id

      // Simply use play(at:) which is the most reliable method
      playerNode.play(at: avAudiotime)

      // Use timer for status notification
      self.startNotificationTimer = Timer(fire: scheduledDate,
                                          interval: 0,
                                          repeats: false) { [weak self] timer in
        guard let self = self else {
          timer.invalidate()
          return
        }

        DispatchQueue.main.async {
          guard let spin = self.spin, spin.id == scheduledSpinId else {
            os_log("Timer fired but spin is nil or has changed", log: SpinPlayer.logger, type: .error)
            timer.invalidate()
            return
          }

          os_log("Timer fired for scheduled play of %@ by %@ (spinID: %@)",
                 log: SpinPlayer.logger, type: .info,
                 spin.audioBlock?.title ?? "unknown",
                 spin.audioBlock?.artist ?? "unknown",
                 spin.id)

          self.state = .playing
          self.delegate?.player(self, startedPlaying: spin)
        }
        timer.invalidate()
      }
      RunLoop.main.add(self.startNotificationTimer!, forMode: .default)

    } catch {
      errorReporter.reportError(error, context: "Failed to schedule playback", level: .error)
    }
  }

  // MARK: File Loading

  /// Loads an AVAudioFile into the current player node
  private func loadFile(_ file: AVAudioFile) {
    playerNode.scheduleFile(file, at: nil)
  }

  public func loadFile(with url: URL) {
    os_log("Attempting to load audio file: %@ for %@ by %@ (spinID: %@)",
           log: SpinPlayer.logger, type: .info,
           url.lastPathComponent,
           spin?.audioBlock?.title ?? "unknown",
           spin?.audioBlock?.artist ?? "unknown",
           spin?.id ?? "unknown")
    do {
      // First check if the file exists and has a reasonable size
      let fileManager = FileManager.default

      guard fileManager.fileExists(atPath: url.path) else {
        let error = FileDownloadError.fileNotFound(url.path)
        errorReporter.reportError(error,
                                  context: "Audio file not found at path",
                                  level: .error)
        self.state = .available
        return
      }

      // Validate file size
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0

      // Consider files under 10KB as suspicious (adjust as needed)
      if fileSize < 10 * 1024 {
        let error = FileDownloadError.downloadFailed("Audio file is too small: \(fileSize) bytes")
        errorReporter.reportError(error,
                                  context: "Suspiciously small file detected: \(url.lastPathComponent)",
                                  level: .error)
        // Delete the invalid file
        try? fileManager.removeItem(at: url)
        self.state = .available
        throw error
      }

      // Attempt to create the audio file object
      do {
        currentFile = try AVAudioFile(forReading: url)
        normalizationCalculator = AudioNormalizationCalculator(currentFile!)
        os_log("Successfully loaded audio file: %@ for %@ (spinID: %@)",
               log: SpinPlayer.logger, type: .info,
               url.lastPathComponent,
               spin?.audioBlock?.title ?? "unknown",
               spin?.id ?? "unknown")
      } catch let audioError as NSError {
        // More detailed context with file information
        let contextInfo = "Failed to load audio file: \(url.lastPathComponent) (size: \(fileSize) bytes)"

        // Handle specific audio format errors
        if audioError.domain == "com.apple.coreaudio.avfaudio" {
          switch audioError.code {
          case 1954115647: // 'fmt?' in ASCII - format error
            errorReporter.reportError(audioError,
                                      context: "\(contextInfo) - Invalid audio format or corrupt file",
                                      level: .error)
            // Delete the corrupt file
            try? fileManager.removeItem(at: url)
          default:
            errorReporter.reportError(audioError, context: contextInfo, level: .error)
          }
        } else {
          errorReporter.reportError(audioError, context: contextInfo, level: .error)
        }

        // State management after error
        self.state = .available
        throw audioError
      }
    } catch {
      // This catch block handles errors from the file validation steps
      // The specific AVAudioFile errors are caught in the inner try-catch
      if !error.localizedDescription.contains("too small") &&
          !error.localizedDescription.contains("not found") {
        errorReporter.reportError(error,
                                  context: "Error during file validation: \(url.lastPathComponent)",
                                  level: .error)
      }
      // State is already set to .available in the inner catch blocks
      self.state = .available
    }
  }

  fileprivate func fadePlayer(
    toVolume endVolume: Float,
    overTime time: Float,
    completionBlock: (() -> ())? = nil
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

    // Create display link if not already running
    if activeDisplayLink == nil {
      activeDisplayLink = CADisplayLink(target: self, selector: #selector(updateFades))
      activeDisplayLink?.add(to: .current, forMode: .common)
    }

    // Log fade operation
    os_log("Scheduled volume fade from %.2f to %.2f over %.2f seconds",
           log: SpinPlayer.logger, type: .debug,
           startVolume, endVolume, time)
  }

  @objc private func updateFades(_ displayLink: CADisplayLink) {
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

    // If no more fades, stop the display link
    if activeFades.isEmpty {
      activeDisplayLink?.invalidate()
      activeDisplayLink = nil

      os_log("All volume fades completed",
             log: SpinPlayer.logger, type: .debug)
    }
  }

  public func scheduleFades(_ spin: Spin) {
    for fade in spin.fades {
      let fadeTime = spin.airtime.addingTimeInterval(TimeInterval(fade.atMS/1000))
      let timer = Timer(fire: fadeTime,
                        interval: 0,
                        repeats: false) { [weak self, fade] timer in
        guard let self = self else { return }
        timer.invalidate()
        self.fadePlayer(toVolume: fade.toVolume, overTime: 1.5)
      }
      RunLoop.main.add(timer, forMode: .default)
      fadeTimers.insert(timer)
    }
  }

  private func setClearTimer(_ spin: Spin?) {
    guard let endtime = spin?.endtime else {
      self.clearTimer?.invalidate()
      return
    }

    // for now, fire a timer. Later we should try and use a callback
    self.clearTimer = Timer(fire: endtime.addingTimeInterval(1),
                            interval: 0,
                            repeats: false, block: { [weak self] timer in
      guard let self = self else { return }

      DispatchQueue.main.async {
        self.stopAudio()
        self.clear()
      }
      timer.invalidate()
    })
    RunLoop.main.add(self.clearTimer!, forMode: .default)
  }
}
