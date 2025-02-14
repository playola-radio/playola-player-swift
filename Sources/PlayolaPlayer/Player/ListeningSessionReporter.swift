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

struct ListeningSessionRequest: Codable {
  let deviceId: String
  let stationId: String?
  let stationUrl: String? = nil
}

@MainActor
public class ListeningSessionReporter {
  var deviceId: String? {
    return UIDevice.current.identifierForVendor?.uuidString
  }
  var timer: Timer?
  let basicToken = "aW9zQXBwOnNwb3RpZnlTdWNrc0FCaWcx" // TODO: De-hard-code this
  var currentSessionStationId: String?
  var disposeBag = Set<AnyCancellable>()
  weak var stationPlayer: PlayolaStationPlayer?
  var currentListeningSessionID: String?

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
      print("Cannot send listeningSession -- missing identifier")
      return
    }
    let url = URL(string: "https://admin-api.playola.fm/v1/listeningSessions/end")!
    let requestBody = [ "deviceId": deviceId]

    guard let jsonData = try? JSONEncoder().encode(requestBody) else {
      print("Error: unable to encode request body to JSON for end listeningSession")
      return
    }

    var request = createPostRequest(url: url, jsonData: jsonData)
    // Create a URLSession task to send the request
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        print("Error: \(error.localizedDescription)")
        return
      }

      if let httpResponse = response as? HTTPURLResponse {
        print("Response Status Code: \(httpResponse.statusCode)")
      }

      if let data = data, let responseString = String(data: data, encoding: .utf8) {
        print("Response Data: \(responseString)")
      }
    }
    task.resume()
  }

  public func reportOrExtendListeningSession(_ stationId: String) {
    guard let deviceId else {
      print("Cannot send listeningSession -- missing identifier")
      return
    }
    let url = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!

    // Create an instance of the Codable struct
    let requestBody = ListeningSessionRequest(
      deviceId: deviceId,
      stationId: stationId)

    // Convert the Codable struct to JSON data
    guard let jsonData = try? JSONEncoder().encode(requestBody) else {
      print("Error: Unable to encode request body to JSON")
      return
    }

    // Create the request
    var request = createPostRequest(url: url, jsonData: jsonData)

    // Create a URLSession task to send the request
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        print("Error: \(error.localizedDescription)")
        return
      }

      if let httpResponse = response as? HTTPURLResponse {
        print("Response Status Code: \(httpResponse.statusCode)")
      }

      if let data = data, let responseString = String(data: data, encoding: .utf8) {
        print("Response Data: \(responseString)")
      }
    }
    task.resume()
  }

  private func startPeriodicNotifications() {
    self.timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true, block: { [weak self] timer in
      guard let self else { return }
      guard let stationId = self.stationPlayer?.stationId else {
        print("Error -- stationId should exist")
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
