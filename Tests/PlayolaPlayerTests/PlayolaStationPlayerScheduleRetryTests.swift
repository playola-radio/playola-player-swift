import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct PlayolaStationPlayerScheduleRetryTests {

  /// Encodes the mock schedule into the same wire format the server returns
  /// (a top-level array of spins) so `getUpdatedSchedule` can decode it.
  private func validScheduleData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(.iso8601Full)
    return try encoder.encode(Schedule.mock.spins)
  }

  private func makePlayer(session: MockURLSession) -> PlayolaStationPlayer {
    let player = PlayolaStationPlayer(
      fileDownloadManager: MockFileDownloadManager(),
      urlSession: session)
    player.scheduleRetryBaseDelay = 0  // keep backoff instant in tests
    return player
  }

  // MARK: - Issue 1: bounded backoff for the initial schedule fetch

  @Test("Retries a transient 500 then succeeds")
  func testRetriesTransientThenSucceeds() async throws {
    let session = MockURLSession()
    session.addResponse(statusCode: 500)
    session.addResponse(statusCode: 500)
    session.addResponse(data: try validScheduleData(), statusCode: 200)
    let player = makePlayer(session: session)

    let schedule = try await player.getUpdatedScheduleWithRetry(stationId: "station-1")

    #expect(session.requestCallCount == 3)
    #expect(!schedule.spins.isEmpty)
  }

  @Test("Gives up and throws after exhausting retries on persistent 500")
  func testGivesUpAfterMaxRetries() async throws {
    let session = MockURLSession()
    for _ in 0..<10 { session.addResponse(statusCode: 500) }
    let player = makePlayer(session: session)

    await #expect(throws: (any Error).self) {
      _ = try await player.getUpdatedScheduleWithRetry(stationId: "station-1")
    }

    // initial attempt + 3 retries
    #expect(session.requestCallCount == 4)
  }

  @Test("Does not retry a 404 (permanent) error")
  func testDoesNotRetryClientError() async throws {
    let session = MockURLSession()
    for _ in 0..<10 { session.addResponse(statusCode: 404) }
    let player = makePlayer(session: session)

    await #expect(throws: (any Error).self) {
      _ = try await player.getUpdatedScheduleWithRetry(stationId: "station-1")
    }

    #expect(session.requestCallCount == 1)
  }

  // MARK: - Issue 2: terminal state emitted from play()

  @Test("play emits .loading then .error when the schedule fetch fails")
  func testPlayEmitsErrorStateOnFailure() async throws {
    let session = MockURLSession()
    for _ in 0..<10 { session.addResponse(statusCode: 404) }
    let player = makePlayer(session: session)

    let recorder = StateRecorder()
    player.delegate = recorder

    await #expect(throws: (any Error).self) {
      try await player.play(stationId: "station-1")
    }

    #expect(recorder.tags.contains("loading"))
    #expect(recorder.tags.last == "error")
    if case .error = player.state {
    } else {
      Issue.record("Expected player.state to be .error, got \(player.state)")
    }
  }
}

/// Records the sequence of state transitions reported via the delegate.
@MainActor
private final class StateRecorder: PlayolaStationPlayerDelegate {
  var tags: [String] = []

  nonisolated func player(
    _ player: PlayolaStationPlayer,
    playerStateDidChange state: PlayolaStationPlayer.State
  ) {
    let tag: String
    switch state {
    case .loading: tag = "loading"
    case .playing: tag = "playing"
    case .idle: tag = "idle"
    case .error: tag = "error"
    }
    MainActor.assumeIsolated { tags.append(tag) }
  }
}
