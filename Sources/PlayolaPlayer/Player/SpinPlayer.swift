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

/// Handles audioPlay for a single spin at a time.
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
  private let engine: AVAudioEngine! = PlayolaMainMixer.shared.engine!

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

    /// Install tap
    //        playerNode.installTap(onBus: 0, bufferSize: TapProperties.default.bufferSize, format: TapProperties.default.format, block: onTap(_:_:))
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

    stopAudio()
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
    self.spin = nil
    self.currentFile = nil
    self.state = .available
    self.clearTimer?.invalidate()
    self.startNotificationTimer?.invalidate()
    for timer in fadeTimers {
      timer.invalidate()
    }
    self.volume = 1.0
  }

  /// Play a segment of the song immediately
  public func playNow(from: Double, to: Double? = nil) {
    do {
      // Make sure audio session is configured before playback
      playolaMainMixer.configureAudioSession()
      try engine.start()

      // calculate segment info
      let sampleRate = playerNode.outputFormat(forBus: 0).sampleRate
      let newSampleTime = AVAudioFramePosition(sampleRate * from)
      let framesToPlay = AVAudioFrameCount(Float(sampleRate) * Float(duration))

      // stop the player, schedule the segment, restart the player
      self.volume = 1.0
      playerNode.stop()
      playerNode.scheduleSegment(currentFile!, startingFrame: newSampleTime, frameCount: framesToPlay, at: nil, completionHandler: nil)
      playerNode.play()

      self.state = .playing
      if let spin {
        delegate?.player(self, startedPlaying: spin)
      }
    } catch {
      errorReporter.reportError(error,
                                context: "Failed to start playback at position \(from)s for spin ID: \(spin?.id ?? "unknown")",
                                level: .error)
      self.state = .available
    }
  }

  public func load(_ spin: Spin, onDownloadProgress: ((Float) -> Void)? = nil, onDownloadCompletion: ((URL) -> Void)? = nil) {
    self.state = .loading
    self.spin = spin

    guard let audioFileUrlStr = spin.audioBlock?.downloadUrl,
          let audioFileUrl = URL(string: audioFileUrlStr) else {
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
      return
    }

    // Cancel any existing download
    if let activeDownloadId = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: activeDownloadId)
      self.activeDownloadId = nil
    }

    // Use the new Result-based API
    let downloadId = fileDownloadManager.downloadFile(
      remoteUrl: audioFileUrl,
      progressHandler: { progress in
        onDownloadProgress?(progress)
      },
      completion: { [weak self] result in
        guard let self = self else { return }

        // Clear the active download ID
        self.activeDownloadId = nil

        switch result {
        case .success(let localUrl):
          onDownloadCompletion?(localUrl)

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

        case .failure(let error):
          self.errorReporter.reportError(error, context: "Failed to download audio file: \(audioFileUrl.lastPathComponent)", level: .error)
          self.state = .available
        }
      }
    )

    // Store the download ID for potential cancellation
    self.activeDownloadId = downloadId
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
  public func schedulePlay(at scheduledDate: Date) {
    do {
      // Make sure audio session is configured before scheduling playback
      playolaMainMixer.configureAudioSession()
      try engine.start()
      let avAudiotime = avAudioTimeFromDate(date: scheduledDate)
      playerNode.play(at: avAudiotime)

      // for now, fire a timer
      self.startNotificationTimer = Timer(fire: scheduledDate,
                                          interval: 0,
                                          repeats: false, block: { [weak self] timer in
        guard let self = self else { return }

        DispatchQueue.main.async {
          guard let spin = self.spin else { return }
          self.state = .playing
          self.delegate?.player(self, startedPlaying: spin)
        }
      })
      RunLoop.main.add(self.startNotificationTimer!, forMode: .default)

    } catch {
      errorReporter.reportError(error, context: "Failed to schedule playback", level: .error)
    }
  }

  /// Pauses playback (pauses the engine and player node)
  func pause() {
    os_log("%@ - %d", log: SpinPlayer.logger, type: .default, #function, #line)

    guard isPlaying, let _ = currentFile else {
      return
    }

    playerNode.pause()
    engine.pause()
    //    delegate?.player(self, didChangePlaybackState: false)
  }

  // MARK: File Loading

  /// Loads an AVAudioFile into the current player node
  private func loadFile(_ file: AVAudioFile) {
    playerNode.scheduleFile(file, at: nil)
  }

  /// Loads an audio file at the provided URL into the player node
  public func loadFile(with url: URL) {
    do {
      currentFile = try AVAudioFile(forReading: url)
      normalizationCalculator = AudioNormalizationCalculator(currentFile!)
    } catch {
      // More detailed context with file information
      let filename = url.lastPathComponent
      let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
      let context = "Failed to load audio file: \(filename) (size: \(fileSize) bytes)"
      errorReporter.reportError(error, context: context, level: .error)
      // State management after error
      self.state = .available
    }
  }

  // MARK: Tap
  private func onTap(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
    guard let file = currentFile,
          let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(
            forNodeTime: nodeTime) else {
      // We don't report this as an error because it could happen during normal operation
      return
    }

    let currentTime = TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
    delegate?.player(self, didPlayFile: file, atTime: currentTime, withBuffer: buffer)
  }

  fileprivate func fadePlayer(
    toVolume endVolume : Float,
    overTime time : Float,
    completionBlock: (()->())? = nil) {

      let startVolume = self.volume
      let startTime = DispatchTime.now()
      let totalDuration = Double(time)

      // Use a single timer instead of many dispatch blocks
      let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
        guard let self = self else {
          timer.invalidate()
          return
        }

        let elapsedTime = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
        let fraction = min(elapsedTime / totalDuration, 1.0)

        self.volume = startVolume + (endVolume - startVolume) * Float(fraction)

        if fraction >= 1.0 {
          timer.invalidate()
          completionBlock?()
        }
      }
      RunLoop.main.add(timer, forMode: .common)
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
