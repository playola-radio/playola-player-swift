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

  @Test("A failed play() does not tear down a prior session's scheduling loop")
  func testFailedPlayDoesNotCancelPriorSchedulingTask() async throws {
    let session = MockURLSession()
    for _ in 0..<10 { session.addResponse(statusCode: 404) }
    let player = makePlayer(session: session)

    // A poll loop owned by a prior successful session. A failed later play()
    // must not reach across and cancel work it did not start (Marge #3); the
    // generation token — not a force-cancel — is what protects the new state.
    let priorLoop = Task<Void, Never> {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
    }
    player.schedulingTask = priorLoop

    await #expect(throws: (any Error).self) {
      try await player.play(stationId: "station-1")
    }

    #expect(!priorLoop.isCancelled)
    priorLoop.cancel()
  }

  @Test("Playback callbacks from a superseded generation are gated out")
  func testGenerationGateRejectsStaleWork() async throws {
    let session = MockURLSession()
    for _ in 0..<10 { session.addResponse(statusCode: 404) }
    let player = makePlayer(session: session)

    // A failed play() still bumps the generation (last play() wins).
    await #expect(throws: (any Error).self) {
      try await player.play(stationId: "station-1")
    }

    // `player(_:startedPlaying:)` admits a spin only when its generation is
    // current. An older generation — e.g. a spin scheduled by a prior session —
    // is rejected, which is what stops it overwriting the terminal state
    // (Marge #1). Asserted via the gate directly so the test doesn't construct
    // a CoreAudio-backed SpinPlayer (which hangs headless CI).
    #expect(player.isCurrentGeneration(player.playGeneration))
    #expect(!player.isCurrentGeneration(player.playGeneration - 1))
  }

  @Test("A cancelled download is treated as cancellation, not a terminal error")
  func testDownloadCancelledIsNotTerminalError() async throws {
    let player = makePlayer(session: MockURLSession())

    // Thrown by scheduleSpin when stop() cancels an in-flight download during a
    // station switch — must not flip the new play()'s .loading state to .error.
    #expect(player.isCancellation(FileDownloadError.downloadCancelled))
    #expect(player.isCancellation(CancellationError()))
    #expect(player.isCancellation(URLError(.cancelled)))
    #expect(!player.isCancellation(StationPlayerError.networkError("HTTP error: 500")))
  }

  // MARK: - Marge #2: retry classification limited to connectivity errors

  @Test("A connectivity URLError (timed out) is retried with backoff")
  func testConnectivityURLErrorIsRetried() async throws {
    let session = MockURLSession()
    session.errorToThrow = URLError(.timedOut)
    let player = makePlayer(session: session)

    await #expect(throws: (any Error).self) {
      _ = try await player.getUpdatedScheduleWithRetry(stationId: "station-1")
    }

    #expect(session.requestCallCount == 4)  // initial + 3 retries
  }

  @Test("A non-connectivity URLError (bad URL) fails fast without retrying")
  func testNonConnectivityURLErrorFailsFast() async throws {
    let session = MockURLSession()
    session.errorToThrow = URLError(.badURL)
    let player = makePlayer(session: session)

    await #expect(throws: (any Error).self) {
      _ = try await player.getUpdatedScheduleWithRetry(stationId: "station-1")
    }

    #expect(session.requestCallCount == 1)
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
