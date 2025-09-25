//
//  ListeningSessionReporter.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 2/12/25.
//

import AVFoundation
import Combine
import Foundation

#if os(iOS)
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
    case let .networkError(message):
      return "Network error: \(message)"
    case let .invalidResponse(message):
      return "Invalid response: \(message)"
    case let .encodingError(message):
      return "Encoding error: \(message)"
    case let .authenticationFailed(message):
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

  var timer: Timer?
  let basicToken = "aW9zQXBwOnNwb3RpZnlTdWNrc0FCaWcx"  // TODO: De-hard-code this
  var currentSessionStationId: String?
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
    urlSession: URLSessionProtocol = URLSession.shared,
    baseURL: URL = URL(string: "https://admin-api.playola.fm")!
  ) {
    self.stationPlayer = stationPlayer
    self.authProvider = authProvider
    self.urlSession = urlSession
    self.baseURL = baseURL

    stationPlayer.$stationId.sink { stationId in
      if let stationId {
        Task {
          do {
            try await self.reportOrExtendListeningSession(stationId)
            self.startPeriodicNotifications()
          } catch {
            Task {
              await self.errorReporter.reportError(
                error,
                context: "Failed to initiate listening session for station \(stationId)",
                level: .warning
              )
            }
          }
        }
      } else {
        Task {
          do {
            try await self.endListeningSession()
            self.stopPeriodicNotifications()
          } catch {
            // Just log the error but don't fail critically since this is cleanup
            Task {
              await self.errorReporter.reportError(
                error,
                context: "Failed to cleanly end listening session",
                level: .warning
              )
            }
          }
        }
      }
    }.store(in: &disposeBag)
  }

  deinit {
    self.timer?.invalidate()
    disposeBag.removeAll()
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
          error, context: "Error ending listening session", level: .error
        )
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
      stationId: stationId
    )

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
          error, context: "Error reporting listening session", level: .error
        )
      }
      throw error
    }
  }

  private func startPeriodicNotifications() {
    timer = Timer.scheduledTimer(
      withTimeInterval: 10.0, repeats: true,
      block: { [weak self] _ in
        guard let self else { return }
        guard let stationId = self.stationPlayer?.stationId else {
          let error = ListeningSessionError.invalidResponse(
            "Missing stationId in periodic notification")
          Task {
            await self.errorReporter.reportError(error, level: .warning)
          }
          return
        }

        Task {
          do {
            try await self.reportOrExtendListeningSession(stationId)
          } catch {
            // Log errors but continue running - we'll try again next interval
            Task {
              await self.errorReporter.reportError(
                error,
                context: "Failed periodic listening session update",
                level: .warning
              )
            }
          }
        }
      }
    )
  }

  private func stopPeriodicNotifications() {
    timer?.invalidate()
    timer = nil
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
      Task {
        await errorReporter.reportError(
          ListeningSessionError.authenticationFailed("Max refresh attempts exceeded"),
          context: "Exceeded maximum refresh attempts (\(maxRefreshAttempts))",
          level: .warning
        )
      }

      // Fall back to Basic auth
      try await attemptWithBasicAuth(url: url, requestBody: requestBody)
      return
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
      // Refresh failed - try with Basic auth as fallback
      try await attemptWithBasicAuth(url: url, requestBody: requestBody)
    }
  }

  private func attemptWithBasicAuth(url: URL, requestBody: ListeningSessionRequest) async throws {
    // Create request with Basic auth (bypassing the auth provider)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    do {
      request.httpBody = try JSONEncoder().encode(requestBody)
    } catch {
      throw ListeningSessionError.encodingError(
        "Failed to encode request body: \(error.localizedDescription)")
    }

    request.addValue("Basic \(basicToken)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    let (_, response) = try await urlSession.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ListeningSessionError.invalidResponse("Invalid HTTP response with Basic auth")
    }

    if (200...299).contains(httpResponse.statusCode) {
      // Success with Basic auth
      Task {
        await errorReporter.reportError(
          ListeningSessionError.authenticationFailed("Fell back to Basic auth"),
          context: "Authentication failed, using Basic auth fallback",
          level: .warning
        )
      }
    } else {
      throw ListeningSessionError.authenticationFailed("Both Bearer token and Basic auth failed")
    }
  }

  private func resetRefreshAttempts() {
    refreshAttempts = 0
    lastRefreshAttemptTime = nil
  }

  func createPostRequest<T: Encodable>(url: URL, requestBody: T) async throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    do {
      request.httpBody = try JSONEncoder().encode(requestBody)
    } catch {
      throw ListeningSessionError.encodingError(
        "Failed to encode request body: \(error.localizedDescription)")
    }

    // Use Bearer token if user is authenticated, otherwise fall back to Basic auth
    if let userToken = await authProvider?.getCurrentToken() {
      request.addValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
    } else {
      request.addValue("Basic \(basicToken)", forHTTPHeaderField: "Authorization")
    }

    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  // TODO: Find a better way of doing this.  Protocols + ObservableObject has issues.
  #if DEBUG
    init(
      authProvider: PlayolaAuthenticationProvider? = nil,
      urlSession: URLSessionProtocol = URLSession.shared,
      baseURL: URL = URL(string: "https://admin-api.playola.fm")!
    ) {
      stationPlayer = nil
      self.authProvider = authProvider
      self.urlSession = urlSession
      self.baseURL = baseURL
    }
  #endif
}
