//
//  PlayolaPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Foundation
import os.log
import AVFAudio
import Combine

let baseUrl = URL(string: "https://admin-api.playola.fm/v1")!

/// Errors specific to the station player
public enum StationPlayerError: Error, LocalizedError {
    case networkError(String)
    case scheduleError(String)
    case playbackError(String)
    case invalidStationId(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .scheduleError(let message):
            return "Schedule error: \(message)"
        case .playbackError(let message):
            return "Playback error: \(message)"
        case .invalidStationId(let id):
            return "Invalid station ID: \(id)"
        }
    }
}

@MainActor
final public class PlayolaStationPlayer: ObservableObject {
  @Published public var stationId: String?   // TODO: Change this to Station model
  var currentSchedule: Schedule?
  let fileDownloadManager: FileDownloadManager!
  var listeningSessionReporter: ListeningSessionReporter? = nil
  private let errorReporter = PlayolaErrorReporter.shared

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
    self.listeningSessionReporter = ListeningSessionReporter(stationPlayer: self)
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

  @MainActor
  private func scheduleSpin(spin: Spin, completion: (() -> Void)? = nil) {
      let spinPlayer = getAvailableSpinPlayer()
      if spin.isPlaying {
          spinPlayer.load(spin, onDownloadProgress: { [weak self] progress in
              guard let self = self else { return }
              self.state = .loading(progress)
          }, onDownloadCompletion: { [weak self] localUrl in
              guard let self = self else { return }
              completion?()
              self.state = .playing(spin.audioBlock!)
          })
      } else {
          spinPlayer.load(spin)
          completion?()
      }
  }

  @MainActor
  private func isScheduled(spin: Spin) -> Bool {
    return spinPlayers.filter({$0.spin == spin}).count > 0
  }

  @MainActor
  private func scheduleUpcomingSpins() async {
    guard let stationId else {
      let error = StationPlayerError.invalidStationId("No station ID available")
      errorReporter.reportError(error, level: .warning)
      return
    }

    do {
      let updatedSchedule = try await getUpdatedSchedule(stationId: stationId)
      let spinsToLoad = updatedSchedule.current.filter{$0.airtime < .now + TimeInterval(360)}
      for spin in spinsToLoad {
        if !isScheduled(spin: spin) {
          scheduleSpin(spin: spin)
        }
      }
    } catch {
      errorReporter.reportError(error, context: "Failed to schedule upcoming spins", level: .error)
    }
  }

  private func getUpdatedSchedule(stationId: String) async throws -> Schedule {
    let url = baseUrl.appending(path: "/stations/\(stationId)/schedule")
    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw StationPlayerError.networkError("Invalid response type")
      }

      guard (200...299).contains(httpResponse.statusCode) else {
        throw StationPlayerError.networkError("HTTP error: \(httpResponse.statusCode)")
      }

      let decoder = JSONDecoderWithIsoFull()

      do {
        let spins = try decoder.decode([Spin].self, from: data)
        guard !spins.isEmpty else {
          throw StationPlayerError.scheduleError("No spins returned in schedule")
        }
        return Schedule(stationId: spins[0].stationId, spins: spins)
      } catch {
        errorReporter.reportError(error, context: "Failed to decode schedule response", level: .error)
        throw StationPlayerError.scheduleError("Invalid schedule data: \(error.localizedDescription)")
      }
    } catch {
      errorReporter.reportError(error, context: "Failed to fetch schedule for station: \(stationId)", level: .error)
      throw error
    }
  }

  public func play(stationId: String) async throws {
    self.stationId = stationId
    do {
      self.currentSchedule = try await getUpdatedSchedule(stationId: stationId)
      guard let spinToPlay = currentSchedule?.current.first else {
        throw StationPlayerError.scheduleError("No available spins to play")
      }

      scheduleSpin(spin: spinToPlay) {
        Task {
          await self.scheduleUpcomingSpins()
        }
      }
    } catch {
      errorReporter.reportError(error, context: "Failed to play station: \(stationId)", level: .error)
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
      } catch {
        errorReporter.reportError(error, context: "Error during cleanup after starting playback", level: .warning)
      }
    }
  }


  nonisolated public func player(_ player: SpinPlayer,
                                 didPlayFile file: AVAudioFile,
                                 atTime time: TimeInterval,
                                 withBuffer buffer: AVAudioPCMBuffer) {
    // No error handling needed here
  }

  public func player(_ player: SpinPlayer, didChangeState state: SpinPlayer.State) {
    // No error handling needed here
  }
}


public protocol PlayolaStationPlayerDelegate: AnyObject {
  func player(_ player: PlayolaStationPlayer,
                     playerStateDidChange state: PlayolaStationPlayer.State)
}
