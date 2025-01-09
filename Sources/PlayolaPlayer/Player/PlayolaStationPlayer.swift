//
//  PlayolaPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Foundation
import os.log
import AVFAudio

let baseUrl = URL(string: "https://admin-api.playola.fm/v1")!

@MainActor
final public class PlayolaStationPlayer: Sendable {
  var stationId: String?   // TODO: Change this to Station model
  let fileDownloadManager: FileDownloadManager!

  var activeSpinPlayers: [String: SpinPlayer] = [:]
  var idleSpinPlayers: [SpinPlayer] = []

  public static let shared = PlayolaStationPlayer()

  private init() {
    self.fileDownloadManager = FileDownloadManager()
  }

  private static let logger = OSLog(subsystem: "PlayolaPlayer", category: "PlayolaPlayer")

  private func getAvailableSpinPlayer() -> SpinPlayer {
    if idleSpinPlayers.count == 0 {
      idleSpinPlayers.append(SpinPlayer(delegate: self))
    }
    return idleSpinPlayers.removeFirst()
  }

  private func scheduleSpin(spin: Spin, completion: (() -> Void)? = nil) {
    let spinPlayer = getAvailableSpinPlayer()
    activeSpinPlayers[spin.id] = spinPlayer
    if spin.isPlaying {
      spinPlayer.loadAndSchedule(spin, onDownloadProgress: { progress in
        print(progress)
      }, onDownloadCompletion: { localUrl in
        completion?()
      })
    } else {
      spinPlayer.loadAndSchedule(spin)
    }
  }

  private func isScheduled(spin: Spin) -> Bool {
    return activeSpinPlayers[spin.id] != nil
  }

  private func scheduleUpcomingSpins() async {
    guard let stationId else { return }
    do {
      let updatedSchedule = await try! getUpdatedSchedule(stationId: stationId)
      let spinsToLoad = updatedSchedule.current.filter{$0.airtime < .now + TimeInterval(360)}
      print("spinsToLoad.count: \(spinsToLoad.count)")
      for spin in spinsToLoad {
        if !isScheduled(spin: spin) {
          print("loading upcoming spin: \(spin.audioBlock?.title ?? "uknown")")
          scheduleSpin(spin: spin)
        }
      }

    } catch let error {
      print(error)
    }

  }
  
  private func getUpdatedSchedule(stationId: String) async throws -> Schedule {
    let url = baseUrl.appending(path: "/stations/\(stationId)/schedule")
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoder = JSONDecoderWithIsoFull()
      let spins = try decoder.decode([Spin].self, from: data)
      return Schedule(stationId: spins[0].stationId, spins: spins)
    } catch (let error) {
      throw error
    }
  }

  public func play(stationId: String) async throws {
    self.stationId = stationId
    do {
      let schedule = try await getUpdatedSchedule(stationId: stationId)
      let spinToPlay = schedule.current.first!
      scheduleSpin(spin: spinToPlay) {
        Task {
          await self.scheduleUpcomingSpins()
        }
      }
    } catch (let error) {
      throw error
    }
  }
}


extension PlayolaStationPlayer: SpinPlayerDelegate {
  nonisolated public func player(_ player: SpinPlayer, didChangePlaybackState isPlaying: Bool) {
    Task {
      do {
        await self.scheduleUpcomingSpins()
      } catch let error {
        print(error)
      }
    }
  }

  nonisolated public func player(_ player: SpinPlayer, didPlayFile file: AVAudioFile, atTime time: TimeInterval, withBuffer buffer: AVAudioPCMBuffer) {
    print("didPlayFile")
  }


}

