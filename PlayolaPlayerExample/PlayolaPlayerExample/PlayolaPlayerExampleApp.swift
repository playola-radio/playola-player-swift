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
  init() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
      try session.setActive(true)
    } catch {
      print("Failed to configure AVAudioSession: \(error)")
    }

    NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { notification in
      MainActor.assumeIsolated {
        Self.handleInterruption(notification)
      }
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
