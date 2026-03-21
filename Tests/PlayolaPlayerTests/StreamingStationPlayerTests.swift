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
}

// MARK: - Mock Auth Provider

@MainActor
private final class StreamingMockAuthProvider: PlayolaAuthenticationProvider {
  nonisolated func getCurrentToken() async -> String? { "mock-token" }
  nonisolated func refreshToken() async -> String? { "mock-refreshed-token" }
}
