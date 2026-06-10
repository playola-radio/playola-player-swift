//
//  PlayolaPlayerExampleApp.swift
//  PlayolaPlayerExample
//
//  Created by Brian D Keane on 12/29/24.
//

import AVFoundation
import PlayolaPlayer
import SwiftUI

@main
struct PlayolaPlayerExampleApp: App {
  private let audioSession = HostAudioSession()

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}

/// PlayolaPlayer does not manage the `AVAudioSession` — the host app owns it.
/// This demonstrates the full host contract: configure + activate the session,
/// and drive `pauseForInterruption()` / `resumeAfterInterruption()` from the
/// interruption notifications. A production app would also handle route changes.
@MainActor
final class HostAudioSession {
  /// Retained so the block observer can be removed in deinit and its lifetime
  /// is explicit (NotificationCenter holds the token until removal).
  private var interruptionObserver: (any NSObjectProtocol)?

  init() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
      try session.setActive(true)
    } catch {
      print("Failed to configure AVAudioSession: \(error)")
    }

    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { notification in
      MainActor.assumeIsolated {
        Self.handleInterruption(notification)
      }
    }
  }

  deinit {
    if let interruptionObserver {
      NotificationCenter.default.removeObserver(interruptionObserver)
    }
  }

  private static func handleInterruption(_ notification: Notification) {
    guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    switch type {
    case .began:
      PlayolaStationPlayer.shared.pauseForInterruption()
    case .ended:
      guard let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
        AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
      else { return }
      Task {
        do {
          try AVAudioSession.sharedInstance().setActive(true)
          try await PlayolaStationPlayer.shared.resumeAfterInterruption()
        } catch {
          print("Resume failed: \(error)")
        }
      }
    @unknown default:
      break
    }
  }
}
