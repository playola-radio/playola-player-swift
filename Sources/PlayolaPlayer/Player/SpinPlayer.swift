//
//  AudioPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//

import AVFoundation
import Foundation
import os.log

/// Handles audioPlay for a single spin at a time.
@MainActor
public class SpinPlayer {
  public var id: UUID = UUID()
  public var spin: Spin? {
    didSet { setClearTimer(spin) }
  }

  public var startNotificationTimer: Timer?
  public var clearTimer: Timer?

  public var localUrl: URL? { return currentFile?.url }

  // dependencies
  @objc var playolaMainMixer: PlayolaMainMixer = .shared
  private var fileDownloadManager: FileDownloadManager!

  public weak var delegate: SpinPlayerDelegate?

  public var duration: Double {
    guard let currentFile else { return 0 }
    let audioNodeFileLength = AVAudioFrameCount(currentFile.length)
    return Double(Double(audioNodeFileLength) / 44100)
  }

  public enum State {
    case available
    case playing
    case loaded
    case loading
  }

  public var state: SpinPlayer.State = .available {
    didSet { delegate?.player(self, didChangeState: state) }
  }

  private static let logger = OSLog(subsystem: "fm.playola.playolaCore",
                                    category: "Player")

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



  /// A Bool indicating whether the engine is playing or not
  public var isPlaying: Bool {
    return playerNode.isPlaying
  }

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
      print("Original volume: \(newValue)")
      print("Normalized Volume: \(normalizationCalculator.adjustedVolume(newValue))")
      playerNode.volume = normalizationCalculator.adjustedVolume(newValue)
    }
  }

  /// Singleton instance of the player
  static let shared = SpinPlayer()

  // MARK: Lifecycle

  init(delegate: SpinPlayerDelegate? = nil,
       fileDownloadManager: FileDownloadManager? = nil) {
    self.fileDownloadManager = fileDownloadManager ?? .shared
    self.delegate = delegate

    do {
      let session = AVAudioSession()
      try session.setCategory(
        AVAudioSession.Category(
          rawValue: AVAudioSession.Category.playback.rawValue),
        mode: AVAudioSession.Mode.default,
        options: [
          .allowBluetoothA2DP,
          .defaultToSpeaker,
          .allowAirPlay,
        ])
    } catch {
      os_log("Error setting up session: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
    }

    /// Make connections
    engine.attach(playerNode)
    engine.connect(playerNode,
                   to: playolaMainMixer.mixerNode,
                   format: TapProperties.default.format)
    engine.prepare()

    /// Install tap
    //        playerNode.installTap(onBus: 0, bufferSize: TapProperties.default.bufferSize, format: TapProperties.default.format, block: onTap(_:_:))
  }

  // MARK: Playback

  public func stop() {
    stopAudio()
    clear()
  }

  private func stopAudio() {
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        os_log("Error starting engine while stopping: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
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
  }
  /// play a segment of the song immediately
  private func playNow(from: Double, to: Double? = nil) {
    do {
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
      os_log("Error starting engine: %@",
             log: SpinPlayer.logger,
             type: .default, #function, #line,
             error.localizedDescription)
    }
  }

  public func scheduleFade(at: Date, startingVolume: Float, endingVolume: Float) {
  }

  public func load(_ spin: Spin, onDownloadProgress: ((Float) -> Void)? = nil, onDownloadCompletion: ((URL) -> Void)? = nil) {
    self.state = .loading
    self.spin = spin
    guard let audioFileUrlStr = spin.audioBlock?.downloadUrl, let audioFileUrl = URL(string: audioFileUrlStr) else { return }

    fileDownloadManager.downloadFile(remoteUrl: audioFileUrl) { progress in
      onDownloadProgress?(progress)
    } onCompletion: { localUrl in
      onDownloadCompletion?(localUrl)
      self.loadFile(with: localUrl)
      if spin.isPlaying {
        let currentTimeInSeconds = Date().timeIntervalSince(spin.airtime)
        self.playNow(from: currentTimeInSeconds)
      } else {
        self.schedulePlay(at: spin.airtime)
      }
      self.volume = 1.0
      self.state = .loaded
    }
  }

  private func avAudioTimeFromDate(date: Date) -> AVAudioTime {
    let outputFormat = playerNode.outputFormat(forBus: 0)
    let now = playerNode.lastRenderTime!.sampleTime
    let secsUntilDate = date.timeIntervalSinceNow
    return AVAudioTime(sampleTime: now + Int64(secsUntilDate * outputFormat.sampleRate), atRate: outputFormat.sampleRate)
  }

  /// schedule a future play from the beginning of the file
  public func schedulePlay(at: Date) {
    do {
      try engine.start()
      let avAudiotime = avAudioTimeFromDate(date: at)
      playerNode.play(at: avAudiotime)

      // for now, fire a
      self.startNotificationTimer = Timer(fire: at,
                                          interval: 0,
                                          repeats: false, block: { timer in
        DispatchQueue.main.async {
          guard let spin = self.spin else { return }
          self.state = .playing
          self.delegate?.player(self, startedPlaying: spin)
        }
      })
      RunLoop.main.add(self.startNotificationTimer!, forMode: .default)

    } catch {
      os_log("Error starting engine: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
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
    os_log("%@ - %d", log: SpinPlayer.logger, type: .default, #function, #line)

    do {
      currentFile = try AVAudioFile(forReading: url)
      normalizationCalculator = AudioNormalizationCalculator(currentFile!)
    } catch {
      os_log("Error loading (%@): %@",
             log: SpinPlayer.logger,
             type: .error,
             #function, #line, url.absoluteString, error.localizedDescription)
    }
  }

  // MARK: Tap

  /// Handles the audio tap
  private func onTap(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
    guard let file = currentFile,
          let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(
            forNodeTime: nodeTime) else {
      return
    }

    let currentTime = TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
    delegate?.player(self, didPlayFile: file, atTime: currentTime, withBuffer: buffer)
  }

  private func setClearTimer(_ spin: Spin?) {
    guard let endtime = spin?.endtime else {
      self.clearTimer?.invalidate()
      return
    }

    // for now, fire a
    self.clearTimer = Timer(fire: endtime.addingTimeInterval(1),
                            interval: 0,
                            repeats: false, block: { timer in
      DispatchQueue.main.async {
        self.stopAudio()
        self.clear()
      }
      timer.invalidate()
    })
    RunLoop.main.add(self.clearTimer!, forMode: .default)
  }
}
