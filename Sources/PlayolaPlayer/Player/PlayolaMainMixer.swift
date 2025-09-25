//
//  PlayolaMainMixer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//

import AVFoundation
import Foundation
import os.log

#if os(iOS)
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
      commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false
    )!
  }
}

open class PlayolaMainMixer: NSObject {
  open private(set) var mixerNode: AVAudioMixerNode
  open private(set) var engine: AVAudioEngine

  open var delegate: PlayolaMainMixerDelegate?
  private let errorReporter = PlayolaErrorReporter.shared
  private let audioSessionManager: AudioSessionManager

  private static let logger = OSLog(subsystem: "fm.playola.playolaCore", category: "MainMixer")

  override init() {
    mixerNode = AVAudioMixerNode()
    engine = AVAudioEngine()
    audioSessionManager = AudioSessionManager()

    super.init()
    engine.attach(mixerNode)

    engine.connect(
      mixerNode,
      to: engine.mainMixerNode,
      format: TapProperties.default.format
    )

    engine.prepare()

    mixerNode.installTap(
      onBus: 0,
      bufferSize: TapProperties.default.bufferSize,
      format: TapProperties.default.format,
      block: onTap(_:_:)
    )
  }

  deinit {
    self.mixerNode.removeTap(onBus: 0)
  }

  /// Configures the shared audio session for playback
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
          level: .critical
        )
      }
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
          error, context: "Failed to deactivate audio session", level: .warning
        )
      }
    }
  }

  /// Handles the audio tap
  private func onTap(_ buffer: AVAudioPCMBuffer, _: AVAudioTime) {
    delegate?.player(self, didPlayBuffer: buffer)
  }

  @MainActor
  public static let shared: PlayolaMainMixer = .init()
}

extension PlayolaMainMixer {
  @MainActor
  public func start() throws {
    let maxRetries = 3
    var retryCount = 0
    var lastError: Error?

    while retryCount < maxRetries {
      do {
        try engine.start()
        return
      } catch {
        lastError = error
        retryCount += 1

        if retryCount < maxRetries {
          os_log(
            "Audio engine start failed, retry %d of %d: %@",
            log: PlayolaMainMixer.logger, type: .error,
            retryCount, maxRetries, error.localizedDescription
          )
          Thread.sleep(forTimeInterval: 0.1)  // Short delay before retry
        }
      }
    }

    // If we get here, all retries failed
    if let error = lastError {
      Task {
        await errorReporter.reportError(
          error, context: "Failed to start audio engine after \(maxRetries) attempts",
          level: .critical
        )
      }
      throw error
    }
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
