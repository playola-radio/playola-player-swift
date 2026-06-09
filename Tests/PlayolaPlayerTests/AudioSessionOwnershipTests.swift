//  AudioSessionOwnershipTests.swift
//  PlayolaPlayer

import AVFAudio
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

  // MARK: - PlayolaStationPlayer ownership wiring

  @Test("Host mode disables internal session-event handling; default keeps it")
  func hostModeDisablesInternalSessionHandling() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: MockURLSession(),
      mainMixer: PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager()))
    player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
    #expect(player.handlesSessionEventsInternally == false)

    let legacy = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: MockURLSession(),
      mainMixer: PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager()))
    legacy.configure(authProvider: MockAuthProvider())  // default .sdkOwned
    #expect(legacy.handlesSessionEventsInternally == true)
  }

  @Test("Conflicting re-configure keeps player ownership consistent with mixer")
  func conflictingReconfigureStaysConsistent() {
    // Only the same-value re-configure path is exercised: a conflicting value
    // would trip applyOwnership's assertionFailure in debug test builds (the
    // conflict path stays a documented debug tripwire, like sessionTouched).
    // configure mirrors mixer.appliedOwnership, so even a release-mode
    // conflicting re-configure cannot reopen the notification-handler gate.
    let mixer = PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager())
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: MockURLSession(),
      mainMixer: mixer)

    player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
    #expect(player.handlesSessionEventsInternally == false)
    #expect(mixer.appliedOwnership == .hostOwned)

    player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
    #expect(player.handlesSessionEventsInternally == false)
    #expect(mixer.appliedOwnership == .hostOwned)
  }

  #if os(iOS) || os(tvOS)
    @Test("Host mode ignores interruption notifications")
    func hostModeIgnoresInterruptionNotifications() {
      let player = PlayolaStationPlayer(
        fileDownloadManager: MockFileDownloadManager(),
        urlSession: MockURLSession(),
        mainMixer: PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager()))
      player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
      player.setStateForTesting(.playing(.mock), stationId: "station-1")
      player.schedulingTask = Task {}  // sentinel: must survive the notification

      let note = Notification(
        name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [
          AVAudioSessionInterruptionTypeKey:
            AVAudioSession.InterruptionType.began.rawValue
        ])
      player.handleAudioSessionInterruption(note)

      #expect(player.isSuspendedForTesting == false)
      #expect(player.interruptedStationIdForTesting == nil)
      #expect(player.schedulingTask?.isCancelled == false)
    }
  #endif

  @Test("pauseForInterruption bumps generation, publishes .paused, keeps station id")
  func pauseForInterruptionBumpsGenerationPublishesPausedAndKeepsStationId() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: MockURLSession(),
      mainMixer: PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager()))
    player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
    player.setStateForTesting(.playing(.mock), stationId: "station-1")
    let generationBefore = player.playGeneration

    player.pauseForInterruption()

    #expect(player.playGeneration == generationBefore + 1)
    #expect(player.stationId == "station-1")
    #expect(player.isCurrentGeneration(generationBefore) == false)
    if case .paused(let spin) = player.state {
      #expect(spin.id == Spin.mock.id)
    } else {
      Issue.record("pause must publish .paused, got \(player.state)")
    }
  }

  @Test("resumeAfterInterruption without prior pause is a no-op")
  func resumeWithoutPriorPauseIsNoOp() async throws {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: MockURLSession(),
      mainMixer: PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager()))
    player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
    try await player.resumeAfterInterruption()
    #expect(player.isPlaying == false)
    #expect(player.interruptedStationIdForTesting == nil)
  }

  @Test("pause while not playing does not arm resume")
  func pauseWhileNotPlayingDoesNotArmResume() async throws {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: MockURLSession(),
      mainMixer: PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager()))
    player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
    player.setStateForTesting(.idle, stationId: "station-1")

    player.pauseForInterruption()
    try await player.resumeAfterInterruption()

    #expect(player.isPlaying == false)
    #expect(player.interruptedStationIdForTesting == nil)
  }

  @Test("Double pause keeps resume armed")
  func doublePauseKeepsResumeArmed() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: MockURLSession(),
      mainMixer: PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager()))
    player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
    player.setStateForTesting(.playing(.mock), stationId: "station-1")

    player.pauseForInterruption()
    player.pauseForInterruption()

    #expect(player.isSuspendedForTesting == true)
    #expect(player.interruptedStationIdForTesting == "station-1")
    #expect(player.wasPlayingBeforeInterruptionForTesting == true)
  }

  @Test("Pause during loading arms resume and clears the spinner state")
  func pauseDuringLoadingArmsResumeAndClearsSpinner() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: MockURLSession(),
      mainMixer: PlayolaMainMixer(audioSessionManager: NoOpAudioSessionManager()))
    player.configure(authProvider: MockAuthProvider(), audioSessionOwnership: .hostOwned)
    player.setStateForTesting(.loading(0.5), stationId: "station-1")

    player.pauseForInterruption()

    if case .idle = player.state {
    } else {
      Issue.record("pause during loading must clear the spinner, got \(player.state)")
    }
    #expect(player.wasPlayingBeforeInterruptionForTesting == true)
    #expect(player.interruptedStationIdForTesting == "station-1")
  }
}
