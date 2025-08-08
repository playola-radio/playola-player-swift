//
//  AudioSessionManager.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 8/8/25.
//

import AVFoundation
import Foundation

/// Protocol for managing audio session configuration across platforms
protocol AudioSessionManaging {
  func configureForPlayback() async throws
  func activate() async throws
  func deactivate() async throws
  var isConfigured: Bool { get }
}

#if os(iOS)
  /// iOS implementation using AVAudioSession
  class AudioSessionManager: AudioSessionManaging {
    private var _isConfigured = false
    private let errorReporter: PlayolaErrorReporter

    var isConfigured: Bool { _isConfigured }

    init(errorReporter: PlayolaErrorReporter = .shared) {
      self.errorReporter = errorReporter
    }

    func configureForPlayback() async throws {
      let session = AVAudioSession.sharedInstance()

      // First deactivate with appropriate options to reset state
      do {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        // This is not a critical error, just log it
        await errorReporter.reportError(
          error,
          context: "Non-critical error deactivating audio session before configuration",
          level: .warning
        )
      }

      // Configure for playback category
      try session.setCategory(
        .playback,
        mode: .default,
        options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
      )

      _isConfigured = true
    }

    func activate() async throws {
      if !_isConfigured {
        try await configureForPlayback()
      }

      let session = AVAudioSession.sharedInstance()
      try session.setActive(true)
    }

    func deactivate() async throws {
      guard _isConfigured else { return }

      let session = AVAudioSession.sharedInstance()
      try session.setActive(false, options: .notifyOthersOnDeactivation)
      _isConfigured = false
    }
  }
#endif

#if os(macOS)
  /// macOS implementation - audio session management is handled automatically
  class AudioSessionManager: AudioSessionManaging {
    private var _isConfigured = false

    var isConfigured: Bool { _isConfigured }

    init(errorReporter: PlayolaErrorReporter = .shared) {
      // errorReporter not needed on macOS but kept for API compatibility
    }

    func configureForPlayback() async throws {
      // On macOS, audio configuration is handled automatically by the system
      // No explicit session configuration needed
      _isConfigured = true
    }

    func activate() async throws {
      // On macOS, audio activation is handled automatically
      _isConfigured = true
    }

    func deactivate() async throws {
      // On macOS, audio deactivation is handled automatically
      _isConfigured = false
    }
  }
#endif
