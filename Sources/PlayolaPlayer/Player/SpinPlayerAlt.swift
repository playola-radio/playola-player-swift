//
//  SpinPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/12/25.
//
import AVFoundation
import os.log

@MainActor
public class SpinPlayerAlt: Sendable {
  private static let logger = OSLog(subsystem: "fm.playola.playolaCore",
                                    category: "SpinPlayer")

  public let spin: Spin
  public let currentFile: AVAudioFile
  private let engine: AVAudioEngine! = PlayolaMainMixer.shared.engine!
  private let playerNode = AVAudioPlayerNode()
  weak var delegate: SpinPlayerDelegate?

  public var volume: Float {
    get {
      return playerNode.volume
    }
    set {
      playerNode.volume = newValue
    }
  }

  public var duration: Double {
    return Double(Double(AVAudioFrameCount(currentFile.length)/44100))
  }

  init?(spin: Spin, localUrl: URL, delegate: SpinPlayerDelegate?) {
    self.spin = spin
    self.delegate = delegate

    do {
      let session = AVAudioSession()
      try
      session.setCategory(AVAudioSession.Category(rawValue: AVAudioSession.Category.playAndRecord.rawValue), mode: AVAudioSession.Mode.default, options: [
        .allowBluetoothA2DP,
        .defaultToSpeaker
      ])
    } catch {
      os_log("Error setting up session: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
    }

    do {
      self.currentFile = try AVAudioFile(forReading: localUrl)
    } catch let error {
      os_log("Error loading (%@): %@",
             log: SpinPlayer.logger,
             type: .error,
             #function, #line, localUrl.absoluteString, error.localizedDescription)
      return nil
    }

    if spin.isPlaying {
      let currentTimeInSeconds = Date().timeIntervalSince(spin.airtime)
      playNow(from: currentTimeInSeconds, to: nil)
    } else {
      schedulePlay(at: spin.airtime)
    }
  }
  /// play a segment of the song immediately
  private func playNow(from: Double, to: Double? = nil) {
    do {
      try engine.start()

      // calculate segment info
      let sampleRate = playerNode.outputFormat(forBus: 0).sampleRate
      let newSampleTime = AVAudioFramePosition(sampleRate * from)
      let framesToPlay = AVAudioFrameCount(Float(sampleRate) * Float(duration))

      // stop the player, schedule the segxment, restart the player
      playerNode.volume = 1.0
      playerNode.stop()
      playerNode.scheduleSegment(currentFile,
                                 startingFrame: newSampleTime,
                                 frameCount: framesToPlay,
                                 at: nil,
                                 completionHandler: nil)
      playerNode.play()

      delegate?.player(self, didChangePlaybackState: true)
    } catch {
      os_log("Error starting engine: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
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
      print("Scheduling play at datetime: \(at), avAudioTime:\(avAudiotime)")
      playerNode.play(at: avAudiotime)

      // for now, fire a
//      self.startNotificationTimer = Timer(fire: at,
//                                          interval: 0,
//                                          repeats: false, block: { timer in
//        DispatchQueue.main.async {
//          self.delegate?.player(self, didChangePlaybackState: true)
//        }
//      })
//      RunLoop.main.add(self.startNotificationTimer!, forMode: .default)

    } catch {
      os_log("Error starting engine: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
    }
  }
}
