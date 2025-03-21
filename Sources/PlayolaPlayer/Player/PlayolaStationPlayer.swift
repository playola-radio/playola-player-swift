//
//  PlayolaPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

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
  case fileDownloadError(String)
  
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
    case .fileDownloadError(let message):
      return "File download error: \(message)"
    }
  }
}

@MainActor
final public class PlayolaStationPlayer: ObservableObject {
  @Published public var stationId: String?   // TODO: Change this to Station model
  var currentSchedule: Schedule?
  let fileDownloadManager: FileDownloadManaging
  var listeningSessionReporter: ListeningSessionReporter? = nil
  private let errorReporter = PlayolaErrorReporter.shared
  
  // Track active download IDs for potential cancellation
  private var activeDownloadIds: [String: UUID] = [:]
  
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
  
  private init(fileDownloadManager: FileDownloadManaging = FileDownloadManager.shared) {
    self.fileDownloadManager = fileDownloadManager
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
  private func scheduleSpin(spin: Spin,
                            completion: (() -> Void)? = nil,
                            retryCount: Int = 0) {
    let spinPlayer = getAvailableSpinPlayer()
    
    guard let audioFileUrlStr = spin.audioBlock?.downloadUrl,
          let audioFileUrl = URL(string: audioFileUrlStr) else {
      let spinDetails = """
              Spin ID: \(spin.id)
              Audio Block ID: \(spin.audioBlock?.id ?? "nil")
              Audio Block Title: \(spin.audioBlock?.title ?? "nil")
              Audio Block Artist: \(spin.audioBlock?.artist ?? "nil")
              Download URL: \(spin.audioBlock?.downloadUrl ?? "nil")
          """
      let error = StationPlayerError.playbackError("Invalid audio file URL in spin")
      errorReporter.reportError(
        error,
        context: "Invalid or missing download URL for spin | \(spinDetails)",
        level: .error)
      return
    }
    
    // Maximum retry attempts
    let maxRetries = 3
    
    // Cancel any existing download for this spin
    if let existingDownloadId = activeDownloadIds[spin.id] {
      _ = fileDownloadManager.cancelDownload(id: existingDownloadId)
      activeDownloadIds.removeValue(forKey: spin.id)
    }
    
    if spin.isPlaying {
      // Use new download API with Result type
      let downloadId = fileDownloadManager.downloadFile(
        remoteUrl: audioFileUrl,
        progressHandler: { [weak self] progress in
          guard let self = self else { return }
          self.state = .loading(progress)
        },
        completion: { [weak self] result in
          guard let self = self else { return }
          
          // Remove from active downloads
          self.activeDownloadIds.removeValue(forKey: spin.id)
          
          switch result {
          case .success(let localUrl):
            // Attempt to load the file
            do {
              // Check file size explicitly before attempting to load
              let attributes = try FileManager.default.attributesOfItem(atPath: localUrl.path)
              let fileSize = (attributes[.size] as? UInt64) ?? 0
              
              // Consider files under 10KB as suspicious (adjust as needed)
              if fileSize < 10 * 1024 {
                throw FileDownloadError.downloadFailed(
                  "Downloaded file is too small (\(fileSize) bytes)\n \(audioFileUrlStr)")
              }
              
              // Handle successful download
              spinPlayer.loadFile(with: localUrl)
              let currentTimeInSeconds = Date().timeIntervalSince(spin.airtime)
              spinPlayer.spin = spin
              
              if currentTimeInSeconds >= 0 {
                spinPlayer.playNow(from: currentTimeInSeconds)
                spinPlayer.volume = 1.0
              } else {
                spinPlayer.schedulePlay(at: spin.airtime)
                spinPlayer.volume = spin.startingVolume
              }
              
              spinPlayer.scheduleFades(spin)
              spinPlayer.state = .loaded
              completion?()
              
              if let audioBlock = spin.audioBlock {
                self.state = .playing(audioBlock)
              }
            } catch {
              // Handle file loading failure
              let stationError = StationPlayerError.fileDownloadError(
                "File loaded but appears corrupt: \(audioFileUrlStr) \(error.localizedDescription)")
              self.errorReporter.reportError(stationError, level: .error)
              
              // If we haven't exceeded retry attempts, try again
              if retryCount < maxRetries {
                self.scheduleSpin(spin: spin, completion: completion, retryCount: retryCount + 1)
              }
            }
            
          case .failure(let error):
            // Handle download failure
            let stationError = StationPlayerError.fileDownloadError(error.localizedDescription)
            self.errorReporter.reportError(stationError, level: .error)
            
            // If we haven't exceeded retry attempts, try again
            if retryCount < maxRetries {
              // Add a small delay before retrying (exponential backoff)
              let delay = TimeInterval(0.5 * pow(2.0, Double(retryCount)))
              DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.scheduleSpin(spin: spin, completion: completion, retryCount: retryCount + 1)
              }
            }
          }
        }
      )
      
      // Store the download ID for potential cancellation
      activeDownloadIds[spin.id] = downloadId
      
    } else {
      // For non-playing spins, implementation with retry logic...
      let downloadId = fileDownloadManager.downloadFile(
        remoteUrl: audioFileUrl,
        progressHandler: { _ in },
        completion: { [weak self, weak spinPlayer] result in
          guard let self = self, let spinPlayer = spinPlayer else { return }
          
          // Remove from active downloads
          self.activeDownloadIds.removeValue(forKey: spin.id)
          
          switch result {
          case .success(let localUrl):
            do {
              // Validate file size
              let attributes = try FileManager.default.attributesOfItem(atPath: localUrl.path)
              let fileSize = (attributes[.size] as? UInt64) ?? 0
              
              if fileSize < 10 * 1024 {
                throw FileDownloadError.downloadFailed("Downloaded file is too small (\(fileSize) bytes) \n\(audioFileUrlStr)")
              }
              
              // Load the file
              spinPlayer.loadFile(with: localUrl)
              spinPlayer.spin = spin
              spinPlayer.schedulePlay(at: spin.airtime)
              spinPlayer.volume = spin.startingVolume
              spinPlayer.scheduleFades(spin)
              spinPlayer.state = .loaded
              completion?()
            } catch {
              // Handle file loading failure with retry
              if retryCount < maxRetries {
                let delay = TimeInterval(0.5 * pow(2.0, Double(retryCount)))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                  self.scheduleSpin(spin: spin, completion: completion, retryCount: retryCount + 1)
                }
              } else {
                let stationError = StationPlayerError.fileDownloadError("Failed to load file from \(audioFileUrlStr) after \(maxRetries) attempts: \(error.localizedDescription)")
                self.errorReporter.reportError(stationError, level: .error)
              }
            }
            
          case .failure(let error):
            // Handle download failure with retry
            if retryCount < maxRetries {
              let delay = TimeInterval(0.5 * pow(2.0, Double(retryCount)))
              DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.scheduleSpin(spin: spin, completion: completion, retryCount: retryCount + 1)
              }
            } else {
              let stationError = StationPlayerError.fileDownloadError("Failed to download after \(maxRetries) attempts: \(error.localizedDescription)")
              self.errorReporter.reportError(stationError, level: .error)
            }
          }
        }
      )
      
      // Store the download ID for potential cancellation
      activeDownloadIds[spin.id] = downloadId
    }
  }
  
  @MainActor
  private func isScheduled(spin: Spin) -> Bool {
    return spinPlayers.contains { $0.spin?.id == spin.id }
  }
  
//  @MainActor
//  private func scheduleUpcomingSpins() async {
//    guard let stationId else {
//      let error = StationPlayerError.invalidStationId("No station ID available")
//      errorReporter.reportError(error, level: .warning)
//      return
//    }
//    
//    do {
//      let updatedSchedule = try await getUpdatedSchedule(stationId: stationId)
//      let spinsToLoad = updatedSchedule.current.filter { $0.airtime < .now + TimeInterval(360) }
//      for spin in spinsToLoad {
//        if !isScheduled(spin: spin) {
//          scheduleSpin(spin: spin)
//        }
//      }
//    } catch {
//      errorReporter.reportError(error, context: "Failed to schedule upcoming spins", level: .error)
//    }
//  }

  @MainActor
  private func scheduleUpcomingSpins() async {
      guard let stationId else {
          let error = StationPlayerError.invalidStationId("No station ID available")
          errorReporter.reportError(error, level: .warning)
          return
      }

      do {
          let updatedSchedule = try await getUpdatedSchedule(stationId: stationId)

          // Log how many spins are in the updated schedule
          os_log("Retrieved schedule with %d total spins, %d current spins",
                 log: PlayolaStationPlayer.logger,
                 type: .info,
                 updatedSchedule.spins.count,
                 updatedSchedule.current.count)

          // Extend the time window to load more upcoming spins (10 minutes instead of 6)
          let spinsToLoad = updatedSchedule.current.filter { $0.airtime < .now + TimeInterval(600) }

          os_log("Preparing to load %d upcoming spins",
                 log: PlayolaStationPlayer.logger,
                 type: .info,
                 spinsToLoad.count)

          for spin in spinsToLoad {
              if !isScheduled(spin: spin) {
                  os_log("Scheduling new spin: %@ by %@ at %@",
                         log: PlayolaStationPlayer.logger,
                         type: .info,
                         spin.audioBlock?.title ?? "unknown",
                         spin.audioBlock?.artist ?? "unknown",
                         ISO8601DateFormatter().string(from: spin.airtime))
                  scheduleSpin(spin: spin)
              }
          }

          // Log already scheduled spins
          let scheduledSpinsCount = spinPlayers.filter { $0.spin != nil }.count
          os_log("Total scheduled spins after update: %d",
                 log: PlayolaStationPlayer.logger,
                 type: .info,
                 scheduledSpinsCount)

      } catch {
          errorReporter.reportError(error, context: "Failed to schedule upcoming spins", level: .error)

          // Log more details about the error
          os_log("Schedule update failed: %@",
                 log: PlayolaStationPlayer.logger,
                 type: .error,
                 error.localizedDescription)
      }
  }
  private func getUpdatedSchedule(stationId: String) async throws -> Schedule {
    let url = baseUrl.appending(path: "/stations/\(stationId)/schedule")
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      
      guard let httpResponse = response as? HTTPURLResponse else {
        let error = StationPlayerError.networkError("Invalid response type")
        errorReporter.reportError(error,
                                  context: "Non-HTTP response received from schedule endpoint: \(url.absoluteString)",
                                  level: .error)
        throw error
      }
      
      guard (200...299).contains(httpResponse.statusCode) else {
        let responseText = String(data: data, encoding: .utf8) ?? "Unable to decode response"
        let error = StationPlayerError.networkError("HTTP error: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 404 {
          errorReporter.reportError(error,
                                    context: "Station not found: \(stationId) | Response: \(responseText.prefix(100))",
                                    level: .error)
        } else {
          errorReporter.reportError(error,
                                    context: "HTTP \(httpResponse.statusCode) error getting schedule for station: \(stationId) | Response: \(responseText.prefix(100))",
                                    level: .error)
        }
        throw error
      }
      
      let decoder = JSONDecoderWithIsoFull()
      
      do {
        let spins = try decoder.decode([Spin].self, from: data)
        guard !spins.isEmpty else {
          let error = StationPlayerError.scheduleError("No spins returned in schedule for station ID: \(stationId)")
          errorReporter.reportError(error, level: .error)
          throw error
        }
        return Schedule(stationId: spins[0].stationId, spins: spins)
      } catch let decodingError as DecodingError {
        // Specific handling for different types of decoding errors
        var context: String
        switch decodingError {
        case .dataCorrupted(let reportedContext):
          context = "Corrupted data: \(reportedContext.debugDescription)"
        case .keyNotFound(let key, _):
          context = "Missing key: \(key)"
        case .typeMismatch(let type, _):
          context = "Type mismatch for: \(type)"
        default:
          context = "Unknown decoding error"
        }
        
        errorReporter.reportError(decodingError, context: "Failed to decode schedule: \(context)", level: .error)
        throw StationPlayerError.scheduleError("Invalid schedule data: \(context)")
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
        let error = StationPlayerError.scheduleError("No available spins to play")
        errorReporter.reportError(error,
                                  context: "Schedule for station \(stationId) contains no current spins | Total spins: \(currentSchedule?.spins.count ?? 0)",
                                  level: .error)
        throw error
      }
      
      // Log success with context
      let nowDate = Date()
      let formattedDate = ISO8601DateFormatter().string(from: nowDate)
      os_log("Starting playback for station: %@ | First spin: %@ by %@ at %@",
             log: PlayolaStationPlayer.logger,
             type: .info,
             stationId,
             spinToPlay.audioBlock?.title ?? "unknown",
             spinToPlay.audioBlock?.artist ?? "unknown",
             formattedDate)
      
      scheduleSpin(spin: spinToPlay) {
        Task {
          await self.scheduleUpcomingSpins()
        }
      }
    } catch {
      // Add details about the specific operation that failed
      if let stationError = error as? StationPlayerError {
        switch stationError {
        case .networkError:
          errorReporter.reportError(error,
                                    context: "Network error while fetching schedule for station: \(stationId)",
                                    level: .error)
        case .scheduleError:
          errorReporter.reportError(error,
                                    context: "Schedule error for station: \(stationId)",
                                    level: .error)
        default:
          errorReporter.reportError(error,
                                    context: "Failed to play station: \(stationId) | Error: \(error.localizedDescription)",
                                    level: .error)
        }
      } else {
        errorReporter.reportError(error,
                                  context: "Unexpected error playing station: \(stationId) | Error: \(error.localizedDescription)",
                                  level: .error)
      }
      self.state = .idle
      throw error
    }
  }
  
  public func stop() {
    // Cancel all active downloads
    for (_, downloadId) in activeDownloadIds {
      _ = fileDownloadManager.cancelDownload(id: downloadId)
    }
    activeDownloadIds.removeAll()
    
    // Stop all players
    for player in spinPlayers {
      if player.state != .available {
        player.stop()
      }
    }
    
    self.stationId = nil
    self.currentSchedule = nil
    self.state = .idle
  }
  
  deinit {
    // Ensure all resources are properly cleaned up
    fileDownloadManager.cancelAllDownloads()
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
        
        // Get a list of active file paths to exclude from pruning
        let activePaths = self.spinPlayers
          .compactMap { $0.localUrl?.path }
        
        // Use the new pruning method with proper error handling
        try self.fileDownloadManager.pruneCache(maxSize: nil, excludeFilepaths: activePaths)
      } catch {
        errorReporter.reportError(error, context: "Error during cache pruning after starting playback", level: .warning)
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
