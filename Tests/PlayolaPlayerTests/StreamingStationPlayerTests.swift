import AVFoundation
import Combine
import Foundation
import Testing

@testable import PlayolaCore
@testable import PlayolaPlayer

// MARK: - Mock Schedule Service

/// Captures the mock AVPlayers created during tests so we can inspect them.
@MainActor
final class MockAVPlayerTracker {
  var createdPlayers: [MockAVPlayer] = []

  func createPlayer() -> MockAVPlayer {
    let player = MockAVPlayer()
    createdPlayers.append(player)
    return player
  }
}

// MARK: - Tests

@MainActor
struct StreamingStationPlayerTests {

  private func createStationPlayer(tracker: MockAVPlayerTracker? = nil) -> (
    StreamingStationPlayer, MockAVPlayerTracker
  ) {
    let playerTracker = tracker ?? MockAVPlayerTracker()
    let stationPlayer = StreamingStationPlayer(
      playerFactory: { playerTracker.createPlayer() }
    )
    return (stationPlayer, playerTracker)
  }

  private func createMockSchedule(stationId: String = "test-station") -> Schedule {
    let now = Date()
    let spin = Spin.mockWith(
      id: "current-spin",
      airtime: now.addingTimeInterval(-10),
      stationId: stationId,
      audioBlock: AudioBlock.mockWith(durationMS: 60000, endOfMessageMS: 60000)
    )
    return Schedule(stationId: stationId, spins: [spin])
  }

  // MARK: - Initial State

  @Test("Initial state is idle")
  func testInitialState() {
    let (player, _) = createStationPlayer()
    #expect(player.stationId == nil)
    switch player.state {
    case .idle:
      break
    default:
      Issue.record("Expected idle state")
    }
    #expect(!player.isPlaying)
  }

  // MARK: - Stop

  @Test("Stop resets all state")
  func testStop() {
    let (player, _) = createStationPlayer()
    player.stationId = "test-station"

    player.stop()

    #expect(player.stationId == nil)
    switch player.state {
    case .idle:
      break
    default:
      Issue.record("Expected idle state after stop")
    }
    #expect(player.spinPlayers.isEmpty)
  }

  @Test("Stop clears all spin players")
  func testStopClearsSpinPlayers() async {
    let tracker = MockAVPlayerTracker()
    let (player, _) = createStationPlayer(tracker: tracker)

    // Manually add a spin player to simulate state
    let spin = Spin.mockWith()
    let spinPlayer = StreamingSpinPlayer(
      delegate: player,
      playerFactory: { tracker.createPlayer() }
    )
    _ = await spinPlayer.load(spin)
    player.spinPlayers[spin.id] = spinPlayer

    player.stop()

    #expect(player.spinPlayers.isEmpty)
  }

  // MARK: - Configure

  @Test("Configure sets baseUrl")
  func testConfigureSetsBaseUrl() {
    let (player, _) = createStationPlayer()
    let customURL = URL(string: "https://custom-api.example.com")!

    player.configure(
      authProvider: StreamingMockAuthProvider(),
      baseURL: customURL
    )

    #expect(player.baseUrl == customURL)
  }

  @Test("Configure creates listening session reporter")
  func testConfigureCreatesReporter() {
    let (player, _) = createStationPlayer()

    player.configure(authProvider: StreamingMockAuthProvider())

    #expect(player.listeningSessionReporter != nil)
  }

  // MARK: - Spin Player Delegate

  @Test("Finished spin player is removed from spinPlayers")
  func testFinishedSpinPlayerRemoved() async {
    let tracker = MockAVPlayerTracker()
    let (stationPlayer, _) = createStationPlayer(tracker: tracker)

    let spin = Spin.mockWith()
    let spinPlayer = StreamingSpinPlayer(
      delegate: stationPlayer,
      playerFactory: { tracker.createPlayer() }
    )
    _ = await spinPlayer.load(spin)
    stationPlayer.spinPlayers[spin.id] = spinPlayer

    // Simulate the spin finishing
    stationPlayer.streamingPlayer(spinPlayer, didChangeState: .finished)

    #expect(stationPlayer.spinPlayers[spin.id] == nil)
  }

  // MARK: - isPlaying

  @Test("isPlaying returns true when state is playing")
  func testIsPlayingTrue() {
    let (player, _) = createStationPlayer()
    player.state = .playing(Spin.mockWith())
    #expect(player.isPlaying)
  }

  @Test("isPlaying returns false when state is idle")
  func testIsPlayingFalseIdle() {
    let (player, _) = createStationPlayer()
    player.state = .idle
    #expect(!player.isPlaying)
  }

  @Test("isPlaying returns false when state is loading")
  func testIsPlayingFalseLoading() {
    let (player, _) = createStationPlayer()
    player.state = .loading
    #expect(!player.isPlaying)
  }
  // MARK: - Play Clears Existing Spin Players

  @Test("play() clears existing spin players before starting fresh")
  func testPlayClearsExistingSpinPlayers() async throws {
    let tracker = MockAVPlayerTracker()
    let (player, _) = createStationPlayer(tracker: tracker)

    let mockSchedule = createMockSchedule()
    player.scheduleFetcher = { _, _ in mockSchedule }

    // Manually add existing spin players to simulate pre-interruption state
    let staleSpin = Spin.mockWith(id: "stale-spin-1")
    let staleSpinPlayer = StreamingSpinPlayer(
      delegate: player,
      playerFactory: { tracker.createPlayer() }
    )
    _ = await staleSpinPlayer.load(staleSpin)
    player.spinPlayers["stale-spin-1"] = staleSpinPlayer

    let staleSpin2 = Spin.mockWith(id: "stale-spin-2")
    let staleSpinPlayer2 = StreamingSpinPlayer(
      delegate: player,
      playerFactory: { tracker.createPlayer() }
    )
    _ = await staleSpinPlayer2.load(staleSpin2)
    player.spinPlayers["stale-spin-2"] = staleSpinPlayer2

    #expect(player.spinPlayers.count == 2)

    try await player.play(stationId: "test-station")

    // Stale players should be gone, replaced with fresh ones
    #expect(player.spinPlayers["stale-spin-1"] == nil)
    #expect(player.spinPlayers["stale-spin-2"] == nil)
    #expect(!player.spinPlayers.isEmpty)
  }

  // MARK: - Audio Interruption Handling

  @Test("Interruption began sets correct state when playing")
  func testInterruptionBeganWhilePlaying() {
    let (player, _) = createStationPlayer()
    player.stationId = "test-station"
    player.state = .playing(Spin.mockWith())

    player.handleInterruptionBegan()

    #expect(player.wasPlayingBeforeInterruption == true)
    #expect(player.interruptedStationId == "test-station")
  }

  @Test("Interruption began sets wasPlayingBeforeInterruption false when not playing")
  func testInterruptionBeganWhileNotPlaying() {
    let (player, _) = createStationPlayer()
    player.stationId = "test-station"
    player.state = .idle

    player.handleInterruptionBegan()

    #expect(player.wasPlayingBeforeInterruption == false)
    #expect(player.interruptedStationId == "test-station")
  }

  @Test("Interruption ended with shouldResume triggers resume")
  func testInterruptionEndedWithShouldResume() async throws {
    let tracker = MockAVPlayerTracker()
    let (player, _) = createStationPlayer(tracker: tracker)

    let mockSchedule = createMockSchedule()
    var fetchCount = 0
    player.scheduleFetcher = { _, _ in
      fetchCount += 1
      return mockSchedule
    }

    // Simulate interruption began state
    player.wasPlayingBeforeInterruption = true
    player.interruptedStationId = "test-station"

    player.handleInterruptionEnded(shouldResume: true)

    // Allow the Task in resumeAfterInterruption to execute
    try await Task.sleep(for: .milliseconds(100))

    #expect(fetchCount > 0)
    #expect(player.stationId == "test-station")
  }

  @Test("Interruption ended without shouldResume does not resume")
  func testInterruptionEndedWithoutShouldResume() async throws {
    let (player, _) = createStationPlayer()

    var fetchCount = 0
    player.scheduleFetcher = { _, _ in
      fetchCount += 1
      return createMockSchedule()
    }

    player.wasPlayingBeforeInterruption = true
    player.interruptedStationId = "test-station"

    player.handleInterruptionEnded(shouldResume: false)

    try await Task.sleep(for: .milliseconds(100))

    #expect(fetchCount == 0)
  }

  @Test("resumeAfterInterruption clears interruption flags")
  func testResumeAfterInterruptionClearsFlags() async throws {
    let tracker = MockAVPlayerTracker()
    let (player, _) = createStationPlayer(tracker: tracker)

    let mockSchedule = createMockSchedule()
    player.scheduleFetcher = { _, _ in mockSchedule }

    player.wasPlayingBeforeInterruption = true
    player.interruptedStationId = "test-station"

    player.resumeAfterInterruption()

    try await Task.sleep(for: .milliseconds(100))

    #expect(player.interruptedStationId == nil)
    #expect(player.wasPlayingBeforeInterruption == false)
  }

  @Test("resumeAfterInterruption with nil stationId does nothing")
  func testResumeAfterInterruptionNilStationId() async throws {
    let (player, _) = createStationPlayer()

    var fetchCount = 0
    player.scheduleFetcher = { _, _ in
      fetchCount += 1
      return createMockSchedule()
    }

    player.interruptedStationId = nil

    player.resumeAfterInterruption()

    try await Task.sleep(for: .milliseconds(100))

    #expect(fetchCount == 0)
  }

  // MARK: - Headphone Disconnect

  @Test("Headphone disconnect stops playback without setting interruption state")
  func testHeadphoneDisconnectStopsWithoutInterruptionState() {
    let (player, _) = createStationPlayer()
    player.stationId = "test-station"
    player.state = .playing(Spin.mockWith())

    // Simulate headphone disconnect by calling stop() directly
    // (this is what handleAudioRouteChange does now — just calls stop())
    player.stop()

    #expect(player.stationId == nil)
    #expect(player.interruptedStationId == nil)
    #expect(player.wasPlayingBeforeInterruption == false)
  }
}

// MARK: - Mock Auth Provider

@MainActor
private final class StreamingMockAuthProvider: PlayolaAuthenticationProvider {
  nonisolated func getCurrentToken() async -> String? { "mock-token" }
  nonisolated func refreshToken() async -> String? { "mock-refreshed-token" }
}
