//
//  ListeningSessionReporter.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 2/12/25.
//

import AVFoundation
import Combine
import Foundation
import PlayolaCore

#if os(iOS) || os(tvOS)
  import UIKit
#endif

/// Errors specific to the listening session reporting
public enum ListeningSessionError: Error, LocalizedError {
  case missingDeviceId
  case networkError(String)
  case invalidResponse(String)
  case encodingError(String)
  case authenticationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .missingDeviceId:
      return "Device identifier is not available"
    case .networkError(let message):
      return "Network error: \(message)"
    case .invalidResponse(let message):
      return "Invalid response: \(message)"
    case .encodingError(let message):
      return "Encoding error: \(message)"
    case .authenticationFailed(let message):
      return "Authentication failed: \(message)"
    }
  }
}

@MainActor
public class ListeningSessionReporter {
  public private(set) var baseURL: URL
  public struct ListeningSessionRequest: Codable {
    let deviceId: String
    let stationId: String?
    var stationUrl: String?
  }

  var deviceId: String? {
    return DeviceInfoProvider.identifierForVendor?.uuidString
  }
  /// Background-safe heartbeat. A long-lived Task (not a foreground RunLoop
  /// `Timer`) so it keeps firing while the app is backgrounded and audio is
  /// still rendering. Started from real `.playing` state, cancelled on a real
  /// stop/pause — never tied to the UI/scene lifecycle.
  var heartbeatTask: Task<Void, Never>?
  /// Tail of the serialized lifecycle chain — the most recent start OR end task.
  /// Every new transition awaits this before its own network write, so reports
  /// and `/end`s for a device stay strictly ordered even across a station
  /// switch or a rapid stop→start (no POST can land out of order).
  private var lifecycleTail: Task<Void, Never>?
  /// Seconds between heartbeat POSTs. Each POST extends the backend session by
  /// 10s, so the cadence must stay under that window. Internal so tests can
  /// shrink it; production keeps the default.
  var heartbeatInterval: TimeInterval = 10.0
  /// The station of the currently-active session, or nil when none is active.
  /// Doubles as the guard that stops a stray `.idle`/`.paused` from sending a
  /// bogus `/end` when no session was ever started.
  var currentSessionStationId: String?
  /// True once a `/listeningSessions` POST has actually succeeded for the current
  /// device session — i.e. the backend really created a session. Gates `/end` so
  /// a `.playing` whose first POST failed (auth/network) or was aborted before it
  /// landed never sends a `/end` for a session that doesn't exist server-side.
  /// Sticky across a station switch (one continuous per-device session); reset
  /// only when the session actually ends.
  var remoteSessionStarted = false
  var disposeBag = Set<AnyCancellable>()
  weak var stationPlayer: PlayolaStationPlayer?
  var currentListeningSessionID: String?
  private let errorReporter = PlayolaErrorReporter.shared
  private let authProvider: PlayolaAuthenticationProvider?
  private let urlSession: URLSessionProtocol

  // Retry limit and tracking
  private let maxRefreshAttempts = 3
  private var refreshAttempts = 0
  private var lastRefreshAttemptTime: Date?

  init(
    stationPlayer: PlayolaStationPlayer, authProvider: PlayolaAuthenticationProvider? = nil,
    urlSession: URLSessionProtocol = PlayolaNetworkLoggingSession(
      wrapping: PlayolaTransport.APISession),
    baseURL: URL = URL(string: "https://admin-api.playola.fm")!
  ) {
    self.stationPlayer = stationPlayer
    self.authProvider = authProvider
    self.urlSession = urlSession
    self.baseURL = baseURL

    // Drive the session off real playback state, NOT off `stationId`/the UI
    // lifecycle. `stationId` is set during `.loading` and cleared by `stop()`,
    // so observing it reported failed loads and ended sessions on backgrounding.
    // `$state` only says "playing"/"paused"/"idle", which is what listening is.
    stationPlayer.$state.sink { [weak self] state in
      // `state` is published from the @MainActor player, so delivery is on the
      // main actor: handle it synchronously to preserve state order (an async
      // hop could reorder rapid transitions). Guard with `isMainThread` so a
      // contract violation degrades to a safe async hop instead of crashing the
      // `MainActor.assumeIsolated` precondition.
      if Thread.isMainThread {
        MainActor.assumeIsolated {
          self?.handleStateChange(state)
        }
      } else {
        Task { @MainActor in self?.handleStateChange(state) }
      }
    }.store(in: &disposeBag)
  }

  deinit {
    self.heartbeatTask?.cancel()
    self.lifecycleTail?.cancel()
    disposeBag.removeAll()
  }

  /// Maps published playback state to session lifecycle. Start reporting only
  /// once audio is actually playing; end only on a genuine stop/pause. `.loading`
  /// is deliberately inert so a failed or aborted load never creates a session.
  func handleStateChange(_ state: PlayolaStationPlayer.State) {
    switch state {
    case .playing(let spin):
      startSession(stationId: spin.stationId)
    case .paused, .idle, .error:
      endSessionIfActive()
    case .loading:
      break
    }
  }

  private func startSession(stationId: String) {
    // Already reporting this station — a repeated `.playing` emission must not
    // spin up a second heartbeat.
    if currentSessionStationId == stationId, heartbeatTask != nil { return }
    currentSessionStationId = stationId
    startHeartbeat(stationId: stationId)
  }

  private func endSessionIfActive() {
    // No active session — don't send a bogus `/end`. The initial `.idle` emitted
    // the moment we subscribe to `$state` lands here and is correctly ignored.
    guard currentSessionStationId != nil else { return }
    currentSessionStationId = nil
    let previous = lifecycleTail
    heartbeatTask?.cancel()
    heartbeatTask = nil
    let task = Task { [weak self] in
      // Drain the prior lifecycle write first so `/end` is the last write and
      // can't be re-extended by a heartbeat that lands after it.
      await previous?.value
      guard let self else { return }
      // A new `.playing` started while we were draining — don't end its session.
      guard self.currentSessionStationId == nil else { return }
      // Never created a session server-side (first POST failed/was aborted) —
      // there is nothing to end, so don't send a bogus `/end`.
      guard self.remoteSessionStarted else { return }
      self.remoteSessionStarted = false
      do {
        try await self.endListeningSession()
      } catch {
        await self.errorReporter.reportError(
          error, context: "Failed to cleanly end listening session", level: .warning)
      }
    }
    lifecycleTail = task
  }

  public func endListeningSession() async throws {
    guard let deviceId else {
      let error = ListeningSessionError.missingDeviceId
      Task {
        await errorReporter.reportError(error, level: .warning)
      }
      throw error
    }

    let url = baseURL.appendingPathComponent("v1/listeningSessions/end")
    let requestBody = ["deviceId": deviceId]

    // Use modern async/await API
    do {
      let request = try await createPostRequest(url: url, requestBody: requestBody)
      let (_, response) = try await urlSession.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse,
        (200...299).contains(httpResponse.statusCode)
      else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw ListeningSessionError.invalidResponse("HTTP status code: \(statusCode)")
      }
    } catch {
      Task {
        await errorReporter.reportError(
          error, context: "Error ending listening session", level: .error)
      }
      throw error
    }
  }

  public func reportOrExtendListeningSession(_ stationId: String) async throws {
    guard let deviceId else {
      let error = ListeningSessionError.missingDeviceId
      Task {
        await errorReporter.reportError(error, level: .warning)
      }
      throw error
    }

    let url = baseURL.appendingPathComponent("v1/listeningSessions")

    // Create an instance of the Codable struct
    let requestBody = ListeningSessionRequest(
      deviceId: deviceId,
      stationId: stationId)

    do {
      let request = try await createPostRequest(url: url, requestBody: requestBody)
      let (_, response) = try await urlSession.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ListeningSessionError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode == 401 {
        // Handle 401 with retry limits
        try await handleAuthenticationFailure(url: url, requestBody: requestBody)
      } else if (200...299).contains(httpResponse.statusCode) {
        // Success - reset retry counter
        resetRefreshAttempts()
      } else {
        throw ListeningSessionError.invalidResponse("HTTP status code: \(httpResponse.statusCode)")
      }
    } catch {
      Task {
        await errorReporter.reportError(
          error, context: "Error reporting listening session", level: .error)
      }
      throw error
    }
  }

  /// Starts (or restarts) the heartbeat loop for `stationId`. The station id is
  /// captured here, not re-read from `stationPlayer` each tick, so `stop()`
  /// clearing `stationId` can't race the final loop iteration. A serial
  /// POST-then-sleep loop keeps heartbeats from overlapping if a POST runs long.
  ///
  /// The new loop drains the previous lifecycle write (`await previous?.value`,
  /// where `previous` is the chain tail — a prior heartbeat OR a prior `/end`)
  /// before its first POST, so no station's in-flight POST can land after a
  /// newer transition. Heartbeats and `/end`s stay strictly ordered.
  private func startHeartbeat(stationId: String) {
    let previous = lifecycleTail
    heartbeatTask?.cancel()
    let interval = heartbeatInterval
    let task = Task { [weak self] in
      await previous?.value
      let intervalNanos = UInt64(interval * 1_000_000_000)
      while !Task.isCancelled {
        guard let self else { return }
        // Time the sleep from the START of the POST so the cadence is `interval`,
        // not `interval + network round-trip`. Otherwise under poor connectivity
        // the gap between POSTs exceeds the backend's session window
        // (endTime = lastPOST + 10s) and the session expires between heartbeats —
        // re-introducing the undercount this fix targets.
        let startNanos = DispatchTime.now().uptimeNanoseconds
        do {
          try await self.reportOrExtendListeningSession(stationId)
          // The backend now has a session for this device — `/end` is allowed.
          self.remoteSessionStarted = true
        } catch {
          // A cancellation (real stop/switch) is not a failure — exit quietly.
          if Task.isCancelled { return }
          // Log and keep looping — the next tick retries.
          await self.errorReporter.reportError(
            error, context: "Failed periodic listening session update", level: .warning)
        }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startNanos
        let remaining = intervalNanos > elapsedNanos ? intervalNanos - elapsedNanos : 0
        do {
          try await Task.sleep(nanoseconds: remaining)
        } catch {
          return  // cancelled during sleep
        }
      }
    }
    heartbeatTask = task
    lifecycleTail = task
  }

  private func handleAuthenticationFailure(url: URL, requestBody: ListeningSessionRequest)
    async throws
  {
    // Reset counter if enough time has passed (e.g., 5 minutes)
    if let lastAttempt = lastRefreshAttemptTime,
      Date().timeIntervalSince(lastAttempt) > 300
    {
      resetRefreshAttempts()
    }

    // Check if we've exceeded retry limits
    if refreshAttempts >= maxRefreshAttempts {
      let error = ListeningSessionError.authenticationFailed("Max refresh attempts exceeded")
      Task {
        await errorReporter.reportError(
          error,
          context: "Exceeded maximum refresh attempts (\(maxRefreshAttempts))",
          level: .warning
        )
      }
      throw error
    }

    // Attempt token refresh
    refreshAttempts += 1
    lastRefreshAttemptTime = Date()

    if (await authProvider?.refreshToken()) != nil {
      // Retry with refreshed token
      let refreshedRequest = try await createPostRequest(url: url, requestBody: requestBody)
      let (_, retryResponse) = try await urlSession.data(for: refreshedRequest)

      guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
        throw ListeningSessionError.invalidResponse("Invalid HTTP response after refresh")
      }

      if (200...299).contains(retryHttpResponse.statusCode) {
        // Success - reset retry counter
        resetRefreshAttempts()
      } else if retryHttpResponse.statusCode == 401 {
        // Still 401 after refresh - recursively handle (will increment counter)
        try await handleAuthenticationFailure(url: url, requestBody: requestBody)
      } else {
        throw ListeningSessionError.invalidResponse(
          "HTTP status code after refresh: \(retryHttpResponse.statusCode)")
      }
    } else {
      throw ListeningSessionError.authenticationFailed("Token refresh failed")
    }
  }

  private func resetRefreshAttempts() {
    refreshAttempts = 0
    lastRefreshAttemptTime = nil
  }

  internal func createPostRequest<T: Encodable>(url: URL, requestBody: T) async throws -> URLRequest
  {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    do {
      request.httpBody = try JSONEncoder().encode(requestBody)
    } catch {
      throw ListeningSessionError.encodingError(
        "Failed to encode request body: \(error.localizedDescription)")
    }

    guard let userToken = await authProvider?.getCurrentToken() else {
      throw ListeningSessionError.authenticationFailed("No authentication token available")
    }
    request.addValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")

    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    PlayolaTransport.preferHTTP3(&request)
    return request
  }

  // TODO: Find a better way of doing this.  Protocols + ObservableObject has issues.
  #if DEBUG
    internal init(
      authProvider: PlayolaAuthenticationProvider? = nil,
      urlSession: URLSessionProtocol = PlayolaNetworkLoggingSession(
        wrapping: PlayolaTransport.APISession),
      baseURL: URL = URL(string: "https://admin-api.playola.fm")!
    ) {
      self.stationPlayer = nil
      self.authProvider = authProvider
      self.urlSession = urlSession
      self.baseURL = baseURL
    }
  #endif
}
