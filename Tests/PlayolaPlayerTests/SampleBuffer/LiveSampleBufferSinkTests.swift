//  LiveSampleBufferSinkTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane C/D. Verifies the live sink wires the auto-flush
//  notification (route-change recovery, §13/C2) to its onAutoFlush hook. The
//  full recovery is device-verified; this proves the observer is registered.

import AVFoundation
import Foundation
import Testing

@testable import PlayolaPlayer

struct LiveSampleBufferSinkTests {
  @Test("auto-flush notification invokes onAutoFlush")
  @MainActor
  func autoFlushNotificationFiresHook() {
    let sink = LiveSampleBufferSink()
    var fired = false
    sink.onAutoFlush = { fired = true }

    NotificationCenter.default.post(
      name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
      object: sink.renderer)

    #expect(fired)
  }
}
