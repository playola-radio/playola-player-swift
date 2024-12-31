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
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoder = JSONDecoderWithIsoFull()
      let spins = try decoder.decode([Spin].self, from: data)
      let schedule = Schedule(stationId: spins[0].stationId, spins: spins)
      let spinToPlay = schedule.current.first!
      guard let audioBlock = spinToPlay.audioBlock else {
        print("shit")
        return
      }
      let firstPPSpin = PPSpin(
        key: spinToPlay.id,
        audioFileURL: URL(string: audioBlock.downloadUrl),
        startTime: spinToPlay.airtime,
        beginFadeOutTime: spinToPlay.airtime + TimeInterval(audioBlock.endOfMessageMS / 1000),
        spinInfo: [:])
      let fileDownloader = FileDownloader()
      fileDownloader.download(url: firstPPSpin.audioFileUrl) { progress in
        print("here we are: \(progress)")
      }

    } catch (let error) {
      throw error
    }
  }
}
