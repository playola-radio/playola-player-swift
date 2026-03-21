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
  var timer: Timer?
  var currentSessionStationId: String?
  var disposeBag = Set<AnyCancellable>()
  weak var stationPlayer: PlayolaStationPlayer?
  private let stationIdGetter: () -> String?
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
    self.stationIdGetter = { [weak stationPlayer] in stationPlayer?.stationId }

    subscribeToStationId(stationPlayer.$stationId.eraseToAnyPublisher())
  }

  init(
    stationIdPublisher: AnyPublisher<String?, Never>,
    stationIdGetter: @escaping () -> String?,
    authProvider: PlayolaAuthenticationProvider? = nil,
    urlSession: URLSessionProtocol = URLSession.shared,
    baseURL: URL = URL(string: "https://admin-api.playola.fm")!
  ) {
    self.stationPlayer = nil
    self.authProvider = authProvider
    self.urlSession = urlSession
    self.baseURL = baseURL
    self.stationIdGetter = stationIdGetter

    subscribeToStationId(stationIdPublisher)
  }

  private func subscribeToStationId(_ publisher: AnyPublisher<String?, Never>) {
    publisher.sink { [weak self] stationId in
      guard let self else { return }
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

  private func startPeriodicNotifications() {
    self.timer = Timer.scheduledTimer(
      withTimeInterval: 10.0, repeats: true,
      block: { [weak self] _ in
        guard let self else { return }
        guard let stationId = self.stationIdGetter() else {
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
      })
  }

  private func stopPeriodicNotifications() {
    self.timer?.invalidate()
    self.timer = nil
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
    return request
  }

  #if DEBUG
    internal init(
      authProvider: PlayolaAuthenticationProvider? = nil,
      urlSession: URLSessionProtocol = URLSession.shared,
      baseURL: URL = URL(string: "https://admin-api.playola.fm")!
    ) {
      self.stationPlayer = nil
      self.stationIdGetter = { nil }
      self.authProvider = authProvider
      self.urlSession = urlSession
      self.baseURL = baseURL
    }
  #endif
}
