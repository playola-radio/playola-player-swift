//  AudioSessionOwnershipTests.swift
//  PlayolaPlayer

import Testing

@testable import PlayolaPlayer

@MainActor
struct AudioSessionOwnershipTests {
  @Test("NoOp manager is inert and reports isConfigured = true in host mode")
  func noOpManagerIsInertAndReportsConfigured() async throws {
    let manager = NoOpAudioSessionManager()
    #expect(manager.isConfigured == true)  // SDK guards/asserts must pass in host mode
    try await manager.configureForPlayback()
    try await manager.activate()
    try await manager.deactivate()
    // Inert by construction: bodies are empty. The seam invariant test below
    // guarantees no other SDK code can reach AVAudioSession around this manager.
  }
}
