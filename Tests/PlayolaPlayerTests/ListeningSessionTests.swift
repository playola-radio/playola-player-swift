//  ListeningSessionTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 2/13/25.
//

import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct ListeningSessionTests {

  @Suite("HTTP Request Authorization Headers")
  struct RequestHeaders {
    @Test("Uses Bearer token when auth provider has token")
    func testUsesBearerTokenWhenProvided() async throws {
      let mockAuth = MockAuthProvider(currentToken: "valid.jwt.token")
      let reporter = await ListeningSessionReporter(authProvider: mockAuth)

      // Create a request using the reporter's createPostRequest method
      let requestBody = ["test": "data"]
      let url = URL(string: "https://test.com")!

      let request = try await reporter.createPostRequest(url: url, requestBody: requestBody)

      // Check that Authorization header contains Bearer token
      let authHeader = request.value(forHTTPHeaderField: "Authorization")
      #expect(authHeader == "Bearer valid.jwt.token")
    }

    @Test("Throws when no token available")
    func testThrowsWhenNoToken() async throws {
      let mockAuth = MockAuthProvider(currentToken: nil)
      let reporter = await ListeningSessionReporter(authProvider: mockAuth)

      let requestBody = ["test": "data"]
      let url = URL(string: "https://test.com")!

      await #expect(throws: ListeningSessionError.self) {
        _ = try await reporter.createPostRequest(url: url, requestBody: requestBody)
      }
    }

    @Test("Throws when auth provider is nil")
    func testThrowsWhenProviderIsNil() async throws {
      let reporter = await ListeningSessionReporter(authProvider: nil)

      let requestBody = ["test": "data"]
      let url = URL(string: "https://test.com")!

      await #expect(throws: ListeningSessionError.self) {
        _ = try await reporter.createPostRequest(url: url, requestBody: requestBody)
      }
    }
  }

  @Suite("Token Refresh on 401")
  struct TokenRefreshFlow {
    @Test("Calls refresh token on 401 response")
    func testCallsRefreshOn401() async throws {
      let mockAuth = MockAuthProvider(
        currentToken: "expired.token",
        refreshedToken: "fresh.token"
      )
      let mockURLSession = MockURLSession()

      // First request returns 401
      let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
      mockURLSession.addResponse(statusCode: 401, url: testURL)

      // Second request (after refresh) returns 200
      mockURLSession.addResponse(statusCode: 200, url: testURL)

      let reporter = await ListeningSessionReporter(
        authProvider: mockAuth, urlSession: mockURLSession)

      // This should trigger the 401 handling
      try await reporter.reportOrExtendListeningSession("test-station-id")

      // Verify that refresh was called
      #expect(mockAuth.refreshCallCount == 1)

      // Verify that two HTTP requests were made (initial + retry)
      #expect(mockURLSession.requestCallCount == 2)
    }

    @Test("Throws when token refresh fails")
    func testThrowsWhenRefreshFails() async throws {
      let mockAuth = MockAuthProvider(
        currentToken: "expired.token",
        refreshedToken: nil  // Refresh fails
      )
      let mockURLSession = MockURLSession()

      // First request returns 401
      let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
      mockURLSession.addResponse(statusCode: 401, url: testURL)

      let reporter = await ListeningSessionReporter(
        authProvider: mockAuth, urlSession: mockURLSession)

      await #expect(throws: ListeningSessionError.self) {
        try await reporter.reportOrExtendListeningSession("test-station-id")
      }

      // Verify that refresh was attempted
      #expect(mockAuth.refreshCallCount == 1)

      // Verify only the initial request was made (no fallback)
      #expect(mockURLSession.requestCallCount == 1)
    }

    @Test("Throws after exceeding max refresh attempts")
    func testThrowsAfterMaxRefreshAttempts() async throws {
      let mockAuth = MockAuthProvider(
        currentToken: "expired.token",
        refreshedToken: "still.expired.token"  // Refresh returns token but still gets 401
      )
      let mockURLSession = MockURLSession()

      let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!

      // First request returns 401
      mockURLSession.addResponse(statusCode: 401, url: testURL)

      // All refresh attempts also return 401 (simulating broken refresh token)
      for _ in 0..<3 {
        mockURLSession.addResponse(statusCode: 401, url: testURL)
      }

      let reporter = await ListeningSessionReporter(
        authProvider: mockAuth, urlSession: mockURLSession)

      await #expect(throws: ListeningSessionError.self) {
        try await reporter.reportOrExtendListeningSession("test-station-id")
      }

      // Verify that refresh was called 3 times (max attempts)
      #expect(mockAuth.refreshCallCount == 3)

      // Verify correct number of HTTP requests:
      // 1 initial + 3 refresh attempts = 4 (no fallback)
      #expect(mockURLSession.requestCallCount == 4)
    }

    @Test("Resets retry counter after successful request")
    func testResetsRetryCounterAfterSuccess() async throws {
      let mockAuth = MockAuthProvider(
        currentToken: "expired.token",
        refreshedToken: "fresh.token"
      )
      let mockURLSession = MockURLSession()

      let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!

      // First attempt: 401 then success
      mockURLSession.addResponse(statusCode: 401, url: testURL)
      mockURLSession.addResponse(statusCode: 200, url: testURL)

      let reporter = await ListeningSessionReporter(
        authProvider: mockAuth, urlSession: mockURLSession)

      // First call should succeed after refresh
      try await reporter.reportOrExtendListeningSession("test-station-id")

      // Second attempt: 401 then success (should work again, counter was reset)
      mockURLSession.addResponse(statusCode: 401, url: testURL)
      mockURLSession.addResponse(statusCode: 200, url: testURL)

      // Second call should also succeed
      try await reporter.reportOrExtendListeningSession("test-station-id")

      // Verify that refresh was called twice (once for each attempt)
      #expect(mockAuth.refreshCallCount == 2)

      // Verify correct number of HTTP requests: 2 + 2 = 4
      #expect(mockURLSession.requestCallCount == 4)
    }

    @Test("Succeeds on first request when token is valid")
    func testSucceedsOnFirstRequest() async throws {
      let mockAuth = MockAuthProvider(currentToken: "valid.token")
      let mockURLSession = MockURLSession()

      // First request returns 200 (success)
      let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
      mockURLSession.addResponse(statusCode: 200, url: testURL)

      let reporter = await ListeningSessionReporter(
        authProvider: mockAuth, urlSession: mockURLSession)

      // This should succeed without refreshing
      try await reporter.reportOrExtendListeningSession("test-station-id")

      // Verify that refresh was NOT called
      #expect(mockAuth.refreshCallCount == 0)

      // Verify that only one HTTP request was made
      #expect(mockURLSession.requestCallCount == 1)
    }
  }

  @Suite("Base URL Configuration")
  struct BaseURLConfiguration {
    @Test("Uses custom base URL for listening sessions")
    func testUsesCustomBaseURL() async throws {
      let customBaseURL = URL(string: "http://localhost:3000")!
      let mockSession = MockURLSession()
      let mockAuth = MockAuthProvider(currentToken: "test.token")

      let reporter = await ListeningSessionReporter(
        authProvider: mockAuth,
        urlSession: mockSession,
        baseURL: customBaseURL
      )

      mockSession.addResponse(
        statusCode: 200, url: customBaseURL.appendingPathComponent("v1/listeningSessions"))

      try await reporter.reportOrExtendListeningSession("test-station-id")

      #expect(
        mockSession.lastRequest?.url?.absoluteString == "http://localhost:3000/v1/listeningSessions"
      )
    }

    @Test("Uses default production URL when not specified")
    func testUsesDefaultProductionURL() async throws {
      let mockSession = MockURLSession()
      let mockAuth = MockAuthProvider(currentToken: "test.token")

      let reporter = await ListeningSessionReporter(
        authProvider: mockAuth,
        urlSession: mockSession
      )

      let prodURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
      mockSession.addResponse(statusCode: 200, url: prodURL)

      try await reporter.reportOrExtendListeningSession("test-station-id")

      #expect(
        mockSession.lastRequest?.url?.absoluteString
          == "https://admin-api.playola.fm/v1/listeningSessions")
    }

    @Test("Uses custom base URL for ending sessions")
    func testEndSessionUsesCustomBaseURL() async throws {
      let customBaseURL = URL(string: "http://localhost:8080")!
      let mockSession = MockURLSession()
      let mockAuth = MockAuthProvider(currentToken: "test.token")

      let reporter = await ListeningSessionReporter(
        authProvider: mockAuth,
        urlSession: mockSession,
        baseURL: customBaseURL
      )

      mockSession.addResponse(
        statusCode: 200, url: customBaseURL.appendingPathComponent("v1/listeningSessions/end"))

      try await reporter.endListeningSession()

      #expect(
        mockSession.lastRequest?.url?.absoluteString
          == "http://localhost:8080/v1/listeningSessions/end")
    }
  }

  @Suite("State-driven session lifecycle")
  @MainActor
  struct StateDrivenLifecycle {
    /// Polls until `condition` is true or the timeout elapses. The reporter
    /// drives POSTs from detached Tasks, so assertions must wait for them.
    func waitUntil(
      _ condition: @MainActor @escaping () -> Bool, timeout: TimeInterval = 2.0
    ) async {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
    }

    private func makeReporter(_ session: MockURLSession) -> ListeningSessionReporter {
      ListeningSessionReporter(
        authProvider: MockAuthProvider(currentToken: "valid.token"), urlSession: session)
    }

    @Test("`.playing` starts a session with a POST to /listeningSessions")
    func playingStartsSession() async throws {
      let session = MockURLSession()
      let reporter = makeReporter(session)
      reporter.heartbeatInterval = 60  // keep the heartbeat from repeating mid-test

      reporter.handleStateChange(.playing(.mockWith(stationId: "station-1")))

      await waitUntil { session.requestCallCount >= 1 }
      #expect(session.requestCallCount == 1)
      #expect(
        session.lastRequest?.url?.absoluteString
          == "https://admin-api.playola.fm/v1/listeningSessions")
    }

    @Test("`.loading` does not create a session")
    func loadingDoesNothing() async throws {
      let session = MockURLSession()
      let reporter = makeReporter(session)

      reporter.handleStateChange(.loading(0.5))

      try? await Task.sleep(nanoseconds: 150_000_000)
      #expect(session.requestCallCount == 0)
    }

    @Test("`.idle` after playing ends the session with a POST to /listeningSessions/end")
    func idleAfterPlayingEndsSession() async throws {
      let session = MockURLSession()
      let reporter = makeReporter(session)
      reporter.heartbeatInterval = 60

      reporter.handleStateChange(.playing(.mockWith(stationId: "station-1")))
      await waitUntil { session.requestCallCount >= 1 }

      reporter.handleStateChange(.idle)
      await waitUntil {
        session.lastRequest?.url?.absoluteString.hasSuffix("/listeningSessions/end") == true
      }
      #expect(
        session.lastRequest?.url?.absoluteString
          == "https://admin-api.playola.fm/v1/listeningSessions/end")
    }

    @Test("`.idle` with no active session does not send a bogus /end")
    func idleWithoutSessionSendsNothing() async throws {
      let session = MockURLSession()
      let reporter = makeReporter(session)

      reporter.handleStateChange(.idle)

      try? await Task.sleep(nanoseconds: 150_000_000)
      #expect(session.requestCallCount == 0)
    }

    @Test("`.paused` after playing ends the session")
    func pausedAfterPlayingEndsSession() async throws {
      let session = MockURLSession()
      let reporter = makeReporter(session)
      reporter.heartbeatInterval = 60

      reporter.handleStateChange(.playing(.mockWith(stationId: "station-1")))
      await waitUntil { session.requestCallCount >= 1 }

      reporter.handleStateChange(.paused(.mockWith(stationId: "station-1")))
      await waitUntil {
        session.lastRequest?.url?.absoluteString.hasSuffix("/listeningSessions/end") == true
      }
      #expect(
        session.lastRequest?.url?.absoluteString
          == "https://admin-api.playola.fm/v1/listeningSessions/end")
    }

    @Test("heartbeat keeps POSTing /listeningSessions while playing")
    func heartbeatRepeatsWhilePlaying() async throws {
      let session = MockURLSession()
      let reporter = makeReporter(session)
      reporter.heartbeatInterval = 0.05

      reporter.handleStateChange(.playing(.mockWith(stationId: "station-1")))

      await waitUntil { session.requestCallCount >= 3 }
      #expect(session.requestCallCount >= 3)

      reporter.handleStateChange(.idle)  // stop the heartbeat so the test settles
    }

    @Test("repeated `.playing` for the same station does not start a second heartbeat")
    func duplicatePlayingDoesNotDoubleStart() async throws {
      let session = MockURLSession()
      let reporter = makeReporter(session)
      reporter.heartbeatInterval = 60

      reporter.handleStateChange(.playing(.mockWith(stationId: "station-1")))
      await waitUntil { session.requestCallCount >= 1 }

      reporter.handleStateChange(.playing(.mockWith(stationId: "station-1")))
      try? await Task.sleep(nanoseconds: 150_000_000)

      #expect(session.requestCallCount == 1)
    }

    @Test("switching stations keeps one session — reports the new station, never /end")
    func switchingStationsDoesNotEnd() async throws {
      let session = MockURLSession()
      let reporter = makeReporter(session)
      reporter.heartbeatInterval = 60

      reporter.handleStateChange(.playing(.mockWith(stationId: "station-A")))
      await waitUntil { session.requestCallCount >= 1 }

      reporter.handleStateChange(.playing(.mockWith(stationId: "station-B")))
      await waitUntil { session.requestCallCount >= 2 }

      // A station switch is one continuous per-device session: it must report
      // the new station and must NOT send /end.
      #expect(session.requestedURLs.allSatisfy { !$0.absoluteString.hasSuffix("/end") })
      #expect(
        session.lastRequest?.url?.absoluteString
          == "https://admin-api.playola.fm/v1/listeningSessions")
    }

    @Test("observes player $state: initial .idle is ignored, .playing starts, .idle ends")
    func observesPlayerStateLifecycle() async throws {
      let player = PlayolaStationPlayer()
      let session = MockURLSession()
      let reporter = ListeningSessionReporter(
        stationPlayer: player,
        authProvider: MockAuthProvider(currentToken: "valid.token"),
        urlSession: session)
      reporter.heartbeatInterval = 60

      // The reporter subscribes to `$state`, whose current value is `.idle`.
      // That initial emission must NOT send a bogus /end.
      try? await Task.sleep(nanoseconds: 100_000_000)
      #expect(session.requestCallCount == 0)

      player.setStateForTesting(.playing(.mockWith(stationId: "s1")), stationId: "s1")
      await waitUntil { session.requestCallCount >= 1 }
      #expect(
        session.lastRequest?.url?.absoluteString.hasSuffix("/v1/listeningSessions") == true)

      player.setStateForTesting(.idle, stationId: nil)
      await waitUntil {
        session.lastRequest?.url?.absoluteString.hasSuffix("/listeningSessions/end") == true
      }
      #expect(
        session.lastRequest?.url?.absoluteString.hasSuffix("/v1/listeningSessions/end") == true)
      // Keeps `reporter` alive through the awaits and confirms the session cleared.
      #expect(reporter.currentSessionStationId == nil)
    }
  }
}
