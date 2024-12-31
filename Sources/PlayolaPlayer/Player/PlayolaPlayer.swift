//
//  PlayolaPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Foundation
import os.log

let baseUrl = URL(string: "https://admin-api.playola.fm/v1")!

final public class PlayolaPlayer: Sendable {
  public static let shared: PlayolaPlayer = {
    let instance = PlayolaPlayer()
    return instance
  }()
  private init() {}

  private static let logger = OSLog(subsystem: "PlayolaPlayer", category: "PlayolaPlayer")

  public func play(stationId: String) async throws {
    let url = baseUrl.appending(path: "/stations/\(stationId)/schedule")
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      let decoder = JSONDecoderWithIsoFull()
      let spins = try decoder.decode([Spin].self, from: data)
      print(spins)
    } catch (let error) {
      throw error
    }
  }
}
