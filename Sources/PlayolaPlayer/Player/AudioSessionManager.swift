//
//  AudioSessionManager.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 8/8/25.
//

import AVFoundation
import Foundation
import PlayolaCore

/// Protocol for managing audio session configuration across platforms
protocol AudioSessionManaging {
  func configureForPlayback() async throws
  func activate() async throws
  func deactivate() async throws
  var isConfigured: Bool { get }
}

/// Inert session manager used when the HOST APP owns the process-global
/// AVAudioSession (see `PlayolaAudioSessionOwnership.hostOwned`).
///
/// Reports `isConfigured == true` so SDK guards that gate on configuration
/// become pass-throughs. HOST CONTRACT: the app must configure (.playback)
/// and activate the session before play()/resumeAfterInterruption(); if it
/// doesn't, engine.start() throws and surfaces through the SDK error path.
final class NoOpAudioSessionManager: AudioSessionManaging {
  var isConfigured: Bool { true }
  init() {}
  func configureForPlayback() async throws {}
  func activate() async throws {}
  func deactivate() async throws {}
}

/// Who owns the process-global AVAudioSession.
public enum PlayolaAudioSessionOwnership: Sendable, Equatable {
  /// SDK configures/activates the session itself (legacy default).
  case sdkOwned
  /// Host app owns the session; the SDK never touches it and registers no
  /// AVAudioSession observers. See host-mode contract in README.
  case hostOwned
}

#if os(iOS) || os(tvOS)
  /// iOS/tvOS implementation using AVAudioSession
  class AudioSessionManager: AudioSessionManaging {
    private let errorReporter: PlayolaErrorReporter

    var isConfigured: Bool {
      let session = AVAudioSession.sharedInstance()
      return session.category == .playback
    }

    init(errorReporter: PlayolaErrorReporter = .shared) {
      self.errorReporter = errorReporter
    }

    func configureForPlayback() async throws {
      let session = AVAudioSession.sharedInstance()

      // First deactivate with appropriate options to reset state
      do {
        print(
          "🔊 Calling session.setActive(false, options: .notifyOthersOnDeactivation)"
        )
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        print("🔊 Successfully deactivated session")
      } catch {
        print("🔊 Error deactivating session: \(error)")
        // This is not a critical error, just log it
        await errorReporter.reportError(
          error,
          context:
            "Non-critical error deactivating audio session before configuration",
          level: .warning
        )
      }

      // Configure for playback category
      try session.setCategory(
        .playback,
        mode: .default,
        options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
      )
    }

    func activate() async throws {
      if !isConfigured {
        try await configureForPlayback()
      }

      let session = AVAudioSession.sharedInstance()
      try session.setActive(true)
    }

    func deactivate() async throws {
      guard isConfigured else { return }

      let session = AVAudioSession.sharedInstance()
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
#endif

#if os(macOS)
  /// macOS implementation - audio session management is handled automatically
  class AudioSessionManager: AudioSessionManaging {
    var isConfigured: Bool { true }  // Always configured on macOS

    init(errorReporter: PlayolaErrorReporter = .shared) {
      // errorReporter not needed on macOS but kept for API compatibility
    }

    func configureForPlayback() async throws {
      // On macOS, audio configuration is handled automatically by the system
      // No explicit session configuration needed
    }

    func activate() async throws {
      // On macOS, audio activation is handled automatically
    }

    func deactivate() async throws {
      // On macOS, audio deactivation is handled automatically
    }
  }
#endif
