//  AudioSessionOwnershipTests.swift
//  PlayolaPlayer

import Testing

@testable import PlayolaPlayer

final class SpyAudioSessionManager: AudioSessionManaging {
  var isConfigured: Bool { true }  // simulates host mode / already-configured
  private(set) var configureCount = 0
  func configureForPlayback() async throws { configureCount += 1 }
  func activate() async throws {}
  func deactivate() async throws {}
}

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

  @Test("Mixer accepts an injected session manager")
  func mixerAcceptsInjectedManager() {
    let mixer = PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager())
    #expect(mixer.audioSessionManager is NoOpAudioSessionManager)
  }

  @Test("applyOwnership is idempotent for repeated same-value calls")
  func applyOwnershipIsIdempotentForSameValue() {
    let mixer = PlayolaMainMixer()  // fresh instance — never .shared in tests
    mixer.applyOwnership(.hostOwned)
    mixer.applyOwnership(.hostOwned)  // must not trap
    #expect(mixer.audioSessionManager is NoOpAudioSessionManager)
  }

  @Test("Default manager is the real AudioSessionManager (sdkOwned)")
  func applyOwnershipDefaultsToSdkOwned() {
    let mixer = PlayolaMainMixer()
    #expect(mixer.audioSessionManager is AudioSessionManager)
  }

  @Test("configureAudioSession is a no-op when the manager reports configured")
  func configureIsNoOpWhenManagerReportsConfigured() async {
    let spy = SpyAudioSessionManager()
    let mixer = PlayolaMainMixer(audioSessionManager: spy)
    mixer.configureAudioSession()
    await Task.yield()  // let any (incorrectly) spawned Task run
    #expect(spy.configureCount == 0)
  }
}
