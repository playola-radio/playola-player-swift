//
//  PlayolaPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Foundation
import os.log
import AVFAudio
import SwiftUI

let baseUrl = URL(string: "https://admin-api.playola.fm/v1")!


@MainActor
final public class PlayolaStationPlayer: Sendable, ObservableObject {
  var stationId: String?   // TODO: Change this to Station model
  var currentSchedule: Schedule?
  let fileDownloadManager: FileDownloadManager!

  public weak var delegate: PlayolaStationPlayerDelegate?

  var spinPlayers: [SpinPlayer] = []
  public static let shared = PlayolaStationPlayer()

  public enum State {
    case loading(Float)
    case playing(AudioBlock)
    case idle
  }

  @Published public var state: PlayolaStationPlayer.State = .idle {
    didSet {
      delegate?.player(self, playerStateDidChange: state)
    }
  }

  public var isPlaying: Bool {
    switch state {
    case .playing(_):
      return true
    default:
      return false
    }
  }

  private init() {
    self.fileDownloadManager = FileDownloadManager()
  }

  private static let logger = OSLog(
    subsystem: "PlayolaPlayer",
    category: "PlayolaStationPlayer")

  private func getAvailableSpinPlayer() -> SpinPlayer {
    let availablePlayers = spinPlayers.filter({ $0.state == .available })
    if let available = availablePlayers.first { return available }

    let newPlayer = SpinPlayer(delegate: self)
    spinPlayers.append(newPlayer)
    return newPlayer
  }

  private func scheduleSpin(spin: Spin, completion: (() -> Void)? = nil) {
    let spinPlayer = getAvailableSpinPlayer()
    if spin.isPlaying {
      spinPlayer.load(spin, onDownloadProgress: { progress in
        self.state = .loading(progress)
      }, onDownloadCompletion: { localUrl in
        completion?()
        self.state = .playing(spin.audioBlock!)
      })
    } else {
      spinPlayer.load(spin)
      completion?()
    }
  }

  private func isScheduled(spin: Spin) -> Bool {
    return spinPlayers.filter({$0.spin == spin}).count > 0
  }

  private func scheduleUpcomingSpins() async {
    guard let stationId else { return }
    do {
      let updatedSchedule = await try! getUpdatedSchedule(stationId: stationId)
      let spinsToLoad = updatedSchedule.current.filter{$0.airtime < .now + TimeInterval(360)}
      for spin in spinsToLoad {
        if !isScheduled(spin: spin) {
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
      self.currentSchedule = try await getUpdatedSchedule(stationId: stationId)
      guard let spinToPlay = currentSchedule?.current.first else { return }
      scheduleSpin(spin: spinToPlay) {
        Task {
          await self.scheduleUpcomingSpins()
        }
      }
    } catch (let error) {
      throw error
    }
  }

  public func stop() {
    for player in spinPlayers {
      if player.state != .available {
        player.stop()
      }
    }
    self.stationId = nil
    self.currentSchedule = nil
    self.state = .idle
  }
}


extension PlayolaStationPlayer: SpinPlayerDelegate {
  public func player(_ player: SpinPlayer, startedPlaying spin: Spin) {
    if let audioBlock = spin.audioBlock {
      self.state = .playing(audioBlock)
    }

    Task {
      do {
        await self.scheduleUpcomingSpins()
        self.fileDownloadManager.pruneCache(
          excludeFilepaths: self.spinPlayers
            .filter{ $0.localUrl != nil }
            .map { $0.localUrl!.path }
        )
      } catch let error {
        print(error)
      }
    }
  }


  nonisolated public func player(_ player: SpinPlayer,
                                 didPlayFile file: AVAudioFile,
                                 atTime time: TimeInterval,
                                 withBuffer buffer: AVAudioPCMBuffer) {
    print("didPlayFile")
  }

  public func player(_ player: SpinPlayer, didChangeState state: SpinPlayer.State) {
    print("new state: \(state)")
  }
}


public protocol PlayolaStationPlayerDelegate: AnyObject {
  func player(_ player: PlayolaStationPlayer,
                     playerStateDidChange state: PlayolaStationPlayer.State)
}
