//
//  PlayolaPlayerExampleApp.swift
//  PlayolaPlayerExample
//
//  Created by Brian D Keane on 12/29/24.
//

import AVFoundation
import SwiftUI

@main
struct PlayolaPlayerExampleApp: App {
  init() {
    // PlayolaPlayer does not manage the AVAudioSession — the host app owns it.
    // Configure and activate it for long-form playback before starting a
    // station. Real apps should also observe interruption/route notifications
    // and drive PlayolaStationPlayer.pauseForInterruption() /
    // resumeAfterInterruption(); this example keeps it minimal.
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
      try session.setActive(true)
    } catch {
      print("Failed to configure AVAudioSession: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
