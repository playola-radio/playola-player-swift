//
//  ListeningSessionReporter.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 2/12/25.
//

import Combine
import AVFoundation
import Foundation
import UIKit

/// Errors specific to the listening session reporting
public enum ListeningSessionError: Error, LocalizedError {
    case missingDeviceId
    case networkError(String)
    case invalidResponse(String)
    case encodingError(String)

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
        }
    }
}

@MainActor
public class ListeningSessionReporter {
  public struct ListeningSessionRequest: Codable {
    let deviceId: String
    let stationId: String?
    let stationUrl: String? = nil
  }

  var deviceId: String? {
    return UIDevice.current.identifierForVendor?.uuidString
  }
  var timer: Timer?
  let basicToken = "aW9zQXBwOnNwb3RpZnlTdWNrc0FCaWcx" // TODO: De-hard-code this
  var currentSessionStationId: String?
  var disposeBag = Set<AnyCancellable>()
  weak var stationPlayer: PlayolaStationPlayer?
  var currentListeningSessionID: String?
  private let errorReporter = PlayolaErrorReporter.shared

  init(stationPlayer: PlayolaStationPlayer) {
    self.stationPlayer = stationPlayer

    stationPlayer.$stationId.sink { stationId in
      if let stationId  {
        Task {
            do {
                try await self.reportOrExtendListeningSession(stationId)
                self.startPeriodicNotifications()
            } catch {
                self.errorReporter.reportError(
                    error,
                    context: "Failed to initiate listening session for station \(stationId)",
                    level: .warning
                )
            }
        }
      } else {
        Task {
            do {
                try await self.endListeningSession()
                self.stopPeriodicNotifications()
            } catch {
                // Just log the error but don't fail critically since this is cleanup
                self.errorReporter.reportError(
                    error,
                    context: "Failed to cleanly end listening session",
                    level: .warning
                )
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
      errorReporter.reportError(error, level: .warning)
      throw error
    }

    let url = URL(string: "https://admin-api.playola.fm/v1/listeningSessions/end")!
    let requestBody = ["deviceId": deviceId]

    // Use modern async/await API
    do {
      var request = try createPostRequest(url: url, requestBody: requestBody)
      let (_, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode) else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw ListeningSessionError.invalidResponse("HTTP status code: \(statusCode)")
      }
    } catch {
      errorReporter.reportError(error, context: "Error ending listening session", level: .error)
      throw error
    }
  }

  public func reportOrExtendListeningSession(_ stationId: String) async throws {
    guard let deviceId else {
      let error = ListeningSessionError.missingDeviceId
      errorReporter.reportError(error, level: .warning)
      throw error
    }

    let url = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!

    // Create an instance of the Codable struct
    let requestBody = ListeningSessionRequest(
      deviceId: deviceId,
      stationId: stationId)

    do {
      var request = try createPostRequest(url: url, requestBody: requestBody)
      let (_, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode) else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw ListeningSessionError.invalidResponse("HTTP status code: \(statusCode)")
      }
    } catch {
      errorReporter.reportError(error, context: "Error reporting listening session", level: .error)
      throw error
    }
  }

  private func startPeriodicNotifications() {
    self.timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true, block: { [weak self] timer in
      guard let self else { return }
      guard let stationId = self.stationPlayer?.stationId else {
        let error = ListeningSessionError.invalidResponse("Missing stationId in periodic notification")
        self.errorReporter.reportError(error, level: .warning)
        return
      }

      Task {
        do {
            try await self.reportOrExtendListeningSession(stationId)
        } catch {
            // Log errors but continue running - we'll try again next interval
            self.errorReporter.reportError(
                error,
                context: "Failed periodic listening session update",
                level: .warning
            )
        }
      }
    })
  }

  private func stopPeriodicNotifications() {
    self.timer?.invalidate()
    self.timer = nil
  }

  private func createPostRequest<T: Encodable>(url: URL, requestBody: T) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    do {
      request.httpBody = try JSONEncoder().encode(requestBody)
    } catch {
      throw ListeningSessionError.encodingError("Failed to encode request body: \(error.localizedDescription)")
    }

    request.addValue("Basic \(basicToken)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }
}
