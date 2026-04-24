//
//  PlayolaMainMixer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//

@preconcurrency import AVFoundation
import Foundation
import PlayolaCore
import os.log

#if os(iOS) || os(tvOS)
  import UIKit
#endif

public protocol PlayolaMainMixerDelegate: AnyObject {
  func player(_ mainMixer: PlayolaMainMixer, didPlayBuffer: AVAudioPCMBuffer)
}

/// Default properties for the tap
enum TapProperties {
  case `default`

  /// The amount of samples in each buffer of audio
  var bufferSize: AVAudioFrameCount {
    return 512
  }

  /// The format of the audio in the tap (desired is float 32, non-interleaved)
  var format: AVAudioFormat {
    return AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
  }
}

open class PlayolaMainMixer: NSObject {
  open private(set) var mixerNode: AVAudioMixerNode
  open private(set) var engine: AVAudioEngine

  open var delegate: PlayolaMainMixerDelegate?
  private let errorReporter = PlayolaErrorReporter.shared
  let audioSessionManager: AudioSessionManager

  private static let logger = OSLog(subsystem: "fm.playola.playolaCore", category: "MainMixer")

  override init() {
    self.mixerNode = AVAudioMixerNode()
    self.engine = AVAudioEngine()
    self.audioSessionManager = AudioSessionManager()

    super.init()
    self.engine.attach(self.mixerNode)

    self.engine.connect(
      self.mixerNode,
      to: self.engine.mainMixerNode,
      format: TapProperties.default.format)

    self.engine.prepare()

    self.mixerNode.installTap(
      onBus: 0,
      bufferSize: TapProperties.default.bufferSize,
      format: TapProperties.default.format,
      block: self.onTap(_:_:))
  }

  deinit {
    self.mixerNode.removeTap(onBus: 0)
  }

  /// Configures the shared audio session for playback (fire-and-forget)
  public func configureAudioSession() {
    guard !audioSessionManager.isConfigured else { return }

    Task { @MainActor in
      do {
        try await audioSessionManager.configureForPlayback()
        try await audioSessionManager.activate()
        os_log("Audio session successfully configured", log: PlayolaMainMixer.logger, type: .info)
      } catch {
        let deviceName = DeviceInfoProvider.deviceName
        let systemVersion = DeviceInfoProvider.systemVersion
        await errorReporter.reportError(
          error,
          context:
            "Failed to configure audio session | Device: \(deviceName) | OS: \(systemVersion)",
          level: .critical)
      }
    }
  }

  /// Configures the shared audio session for playback and waits for completion.
  /// Use this before engine.start() to avoid stalling the audio engine.
  @MainActor
  public func ensureAudioSessionConfigured() async throws {
    guard !audioSessionManager.isConfigured else { return }

    do {
      try await audioSessionManager.configureForPlayback()
      try await audioSessionManager.activate()
      os_log("Audio session successfully configured", log: PlayolaMainMixer.logger, type: .info)
    } catch {
      let deviceName = DeviceInfoProvider.deviceName
      let systemVersion = DeviceInfoProvider.systemVersion
      await errorReporter.reportError(
        error,
        context:
          "Failed to configure audio session | Device: \(deviceName) | OS: \(systemVersion)",
        level: .critical)
      throw error
    }
  }

  /// Deactivates the audio session when it's no longer needed
  public func deactivateAudioSession() {
    guard audioSessionManager.isConfigured else { return }

    Task { @MainActor in
      do {
        try await audioSessionManager.deactivate()
        os_log("Audio session deactivated", log: PlayolaMainMixer.logger, type: .info)
      } catch {
        await errorReporter.reportError(
          error, context: "Failed to deactivate audio session", level: .warning)
      }
    }
  }

  /// Handles the audio tap
  private func onTap(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
    self.delegate?.player(self, didPlayBuffer: buffer)
  }

  @MainActor
  public static let shared: PlayolaMainMixer = PlayolaMainMixer()
}

extension PlayolaMainMixer {
  /// Starts the audio engine off the main thread to avoid blocking on
  /// AUIOClient_StartIO during cold hardware initialization (e.g. resuming
  /// from a phone-call interruption). AVAudioEngine.start() is thread-safe;
  /// only the start call itself is dispatched off main.
  @MainActor
  public func start() async throws {
    let engine = self.engine
    do {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try engine.start()
            continuation.resume()
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } catch {
      await errorReporter.reportError(
        error, context: "Failed to start audio engine",
        level: .critical)
      throw error
    }
  }

  @MainActor
  public func restartEngine() async throws {
    os_log("Restarting audio engine", log: PlayolaMainMixer.logger, type: .info)

    if engine.isRunning {
      engine.stop()
    }

    engine.prepare()
    try await start()
  }

  public var isEngineRunning: Bool {
    return engine.isRunning
  }

  public func attach(_ node: AVAudioPlayerNode) {
    engine.attach(node)
  }

  public func connect(
    _ playerNode: AVAudioPlayerNode, to mixerNode: AVAudioMixerNode, format: AVAudioFormat?
  ) {
    engine.connect(playerNode, to: mixerNode, format: format)
  }

  public func prepare() {
    engine.prepare()
  }
}
