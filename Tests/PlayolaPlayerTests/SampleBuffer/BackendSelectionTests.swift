//  BackendSelectionTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane D (T13 / eng-review A3, C5). configure(renderBackend:)
//  selects the backend, defaults to .legacyEngine, and is a real no-op once
//  playback has started (locked) — so a server flag can't flip it mid-session.

import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct BackendSelectionTests {
  @Test("defaults to the legacy engine")
  func defaultsToLegacy() {
    let player = PlayolaStationPlayer(fileDownloadManager: MockFileDownloadManager())
    #expect(player.renderBackend == .legacyEngine)
  }

  @Test("configure(renderBackend:) selects the sample-buffer backend")
  func configureSelectsSampleBuffer() {
    let player = PlayolaStationPlayer(fileDownloadManager: MockFileDownloadManager())
    player.configure(authProvider: MockAuthProvider(), renderBackend: .sampleBuffer)
    #expect(player.renderBackend == .sampleBuffer)
  }

  @Test("the backend is locked once playback has started")
  func lockedAfterFirstPlay() {
    let player = PlayolaStationPlayer(fileDownloadManager: MockFileDownloadManager())
    player.configure(authProvider: MockAuthProvider(), renderBackend: .sampleBuffer)

    player.lockRenderBackendForTesting()  // stands in for the first play()
    player.setRenderBackend(.legacyEngine)  // release no-op, not just a debug assert

    #expect(player.renderBackend == .sampleBuffer)
  }
}
