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
        self.reportOrExtendListeningSession(stationId)
        self.startPeriodicNotifications()
      } else {
        self.endListeningSession()
        self.stopPeriodicNotifications()
      }
    }.store(in: &disposeBag)
  }

  public func endListeningSession() {
    guard let deviceId else {
      let error = ListeningSessionError.missingDeviceId
      errorReporter.reportError(error, level: .warning)
      return
    }

    let url = URL(string: "https://admin-api.playola.fm/v1/listeningSessions/end")!
    let requestBody = [ "deviceId": deviceId]

    guard let jsonData = try? JSONEncoder().encode(requestBody) else {
      let error = ListeningSessionError.encodingError("Failed to encode request body for end listening session")
      errorReporter.reportError(error, level: .error)
      return
    }

    var request = createPostRequest(url: url, jsonData: jsonData)
    // Create a URLSession task to send the request
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else { return }

      if let error = error {
        Task { @MainActor in
          self.errorReporter.reportError(error, context: "Network error while ending listening session", level: .error)
        }
        return
      }

      if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
        Task { @MainActor in
          let error = ListeningSessionError.invalidResponse("HTTP status code: \(httpResponse.statusCode)")
          self.errorReporter.reportError(error, level: .warning)
        }
      }
    }
    task.resume()
  }

  public func reportOrExtendListeningSession(_ stationId: String) {
    guard let deviceId else {
      let error = ListeningSessionError.missingDeviceId
      errorReporter.reportError(error, level: .warning)
      return
    }

    let url = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!

    // Create an instance of the Codable struct
    let requestBody = ListeningSessionRequest(
      deviceId: deviceId,
      stationId: stationId)

    // Convert the Codable struct to JSON data
    guard let jsonData = try? JSONEncoder().encode(requestBody) else {
      let error = ListeningSessionError.encodingError("Failed to encode listening session request")
      errorReporter.reportError(error, level: .error)
      return
    }

    // Create the request
    var request = createPostRequest(url: url, jsonData: jsonData)

    // Create a URLSession task to send the request
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else { return }

      if let error = error {
        Task { @MainActor in
          self.errorReporter.reportError(error, context: "Network error while reporting listening session", level: .error)
        }
        return
      }

      if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
        Task { @MainActor in
          let error = ListeningSessionError.invalidResponse("HTTP status code: \(httpResponse.statusCode)")
          self.errorReporter.reportError(error, level: .warning)
        }
      }
    }
    task.resume()
  }

  private func startPeriodicNotifications() {
    self.timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true, block: { [weak self] timer in
      guard let self else { return }
      guard let stationId = self.stationPlayer?.stationId else {
        let error = ListeningSessionError.invalidResponse("Missing stationId in periodic notification")
        self.errorReporter.reportError(error, level: .warning)
        return
      }
      self.reportOrExtendListeningSession(stationId)
    })
  }

  private func stopPeriodicNotifications() {
    self.timer?.invalidate()
  }

  private func createPostRequest(url: URL, jsonData: Data) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = jsonData
    request.addValue("Basic \(basicToken)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }
}
