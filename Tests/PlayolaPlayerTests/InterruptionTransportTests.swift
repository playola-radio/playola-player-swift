//  InterruptionTransportTests.swift
//  PlayolaPlayer
//
//  Host-driven interruption transport: pauseForInterruption() /
//  resumeAfterInterruption(). The SDK does not own the AVAudioSession or observe
//  interruptions; the host calls these explicitly. None of these tests touch the
//  shared CoreAudio graph: constructing a station player resolves the mixer
//  lazily, and the resume tests exercise only the unarmed early-return path
//  (the armed path would start a real engine).

import AVFAudio
import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct InterruptionTransportTests {
  // Engine-config recovery must NOT fire while idle or host-paused (those paths
  // would otherwise spin up a real engine via restartEngine). Only the guarded
  // skip paths are unit-tested; the active recovery path needs CoreAudio.
  @Test("Engine configuration change is ignored while idle")
  func engineConfigChangeIgnoredWhileIdle() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
    player.setStateForTesting(.idle, stationId: nil)

    player.handleAudioEngineConfigurationChange(
      Notification(name: .AVAudioEngineConfigurationChange))

    if case .idle = player.state {
    } else {
      Issue.record("config change while idle must not change state, got \(player.state)")
    }
  }

  @Test("Engine configuration change is ignored while host-paused")
  func engineConfigChangeIgnoredWhilePaused() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
    player.setStateForTesting(.playing(.mock), stationId: "station-1")
    player.pauseForInterruption()  // sets isSuspended; state -> .paused

    player.handleAudioEngineConfigurationChange(
      Notification(name: .AVAudioEngineConfigurationChange))

    #expect(player.isSuspendedForTesting == true)
    if case .paused = player.state {
    } else {
      Issue.record("config change while paused must not change state, got \(player.state)")
    }
  }

  @Test("pauseForInterruption bumps generation, publishes .paused, keeps station id")
  func pauseBumpsGenerationPublishesPausedAndKeepsStationId() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
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
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
    try await player.resumeAfterInterruption()
    #expect(player.isPlaying == false)
    #expect(player.interruptedStationIdForTesting == nil)
  }

  @Test("pause while not playing does not arm resume")
  func pauseWhileNotPlayingDoesNotArmResume() async throws {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
    player.setStateForTesting(.idle, stationId: "station-1")

    player.pauseForInterruption()
    try await player.resumeAfterInterruption()

    #expect(player.isPlaying == false)
    #expect(player.interruptedStationIdForTesting == nil)
  }

  @Test("Double pause keeps resume armed")
  func doublePauseKeepsResumeArmed() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
    player.setStateForTesting(.playing(.mock), stationId: "station-1")

    player.pauseForInterruption()
    player.pauseForInterruption()

    #expect(player.isSuspendedForTesting == true)
    #expect(player.interruptedStationIdForTesting == "station-1")
    #expect(player.wasPlayingBeforeInterruptionForTesting == true)
  }

  @Test("stop() clears armed interruption state so a later resume can't revive it")
  func stopClearsArmedInterruptionState() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
    player.setStateForTesting(.playing(.mock), stationId: "station-1")
    player.pauseForInterruption()
    #expect(player.interruptedStationIdForTesting == "station-1")  // armed

    player.stop()

    #expect(player.interruptedStationIdForTesting == nil)
    #expect(player.wasPlayingBeforeInterruptionForTesting == false)
    #expect(player.isSuspendedForTesting == false)
  }

  @Test("resumeAfterInterruption after a stop is a no-op")
  func resumeAfterStopIsNoOp() async throws {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
    player.setStateForTesting(.playing(.mock), stationId: "station-1")
    player.pauseForInterruption()
    player.stop()

    // Guard fails (stop cleared the armed fields) → returns before touching the
    // engine, so this never resolves the shared mixer / starts CoreAudio.
    try await player.resumeAfterInterruption()
    #expect(player.isPlaying == false)
  }

  @Test("Pause during loading arms resume and clears the spinner state")
  func pauseDuringLoadingArmsResumeAndClearsSpinner() {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(), urlSession: MockURLSession())
    player.configure(authProvider: MockAuthProvider())
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
