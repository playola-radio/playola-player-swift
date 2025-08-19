//
//  PlayolaPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import AVFAudio
import Combine
import Foundation
import os.log

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

/// A player for Playola stations that manages audio playback, scheduling, and stream management.
///
/// `PlayolaStationPlayer` is the main entry point for apps integrating with the Playola platform.
/// It handles:
/// - Loading and playing audio from Playola stations
/// - Scheduling upcoming audio content
/// - Managing the audio session and playback state
/// - Reporting listening sessions to Playola analytics
///
/// ## Usage Example:
/// ```
/// // Play a specific station
/// try await PlayolaStationPlayer.shared.play(stationId: "station-id-here")
///
/// // Stop playback
/// PlayolaStationPlayer.shared.stop()
///
/// // Observe state changes
/// player.$state.sink { state in
///    // Handle state changes
/// }
/// ```
@MainActor
final public class PlayolaStationPlayer: ObservableObject {
  @Published public var stationId: String?  // TODO: Change this to Station model
  private var interruptedStationId: String?
  var currentSchedule: Schedule?
  let fileDownloadManager: FileDownloadManaging
  var listeningSessionReporter: ListeningSessionReporter?
  private let errorReporter = PlayolaErrorReporter.shared
  private var authProvider: PlayolaAuthenticationProvider?

  /// Time offset for playing station from a different point in time
  /// Negative values play from the past, positive values play from the future
  private var scheduleOffset: TimeInterval?

  // Track active download IDs for potential cancellation
  private var activeDownloadIds: [String: UUID] = [:]

  // Track active async tasks for proper cancellation
  private var schedulingTask: Task<Void, Never>?
  private var playTask: Task<Void, Error>?

  public weak var delegate: PlayolaStationPlayerDelegate?

  // Thread-safe access to spin players - all access must be on main actor
  private var _spinPlayers: [SpinPlayer] = []

  /// Thread-safe access to spin players array
  private var spinPlayers: [SpinPlayer] {
    get {
      MainActor.assumeIsolated {
        return _spinPlayers
      }
    }
    set {
      MainActor.assumeIsolated {
        _spinPlayers = newValue
      }
    }
  }
  public static let shared = PlayolaStationPlayer()

  /// Configure this instance with authentication provider
  /// - Parameters:
  ///   - authProvider: Provider for JWT tokens
  ///   - baseURL: Base URL for API endpoints. Defaults to production URL.
  public func configure(
    authProvider: PlayolaAuthenticationProvider,
    baseURL: URL = URL(string: "https://admin-api.playola.fm")!
  ) {
    self.authProvider = authProvider
    self.listeningSessionReporter = ListeningSessionReporter(
      stationPlayer: self, authProvider: authProvider, baseURL: baseURL)
  }

  public enum State: Sendable {
    case loading(Float)
    case playing(Spin)
    case idle
  }

  @Published public var state: PlayolaStationPlayer.State = .idle {
    didSet {
      delegate?.player(self, playerStateDidChange: state)
    }
  }

  public var isPlaying: Bool {
    switch state {
    case .playing:
      return true
    default:
      return false
    }
  }

  @MainActor
  internal init(fileDownloadManager: FileDownloadManaging? = nil) {
    self.fileDownloadManager = fileDownloadManager ?? FileDownloadManagerAsync.shared
    self.authProvider = nil
    self.listeningSessionReporter = ListeningSessionReporter(stationPlayer: self, authProvider: nil)

    #if os(iOS)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleAudioSessionInterruption(_:)),
        name: AVAudioSession.interruptionNotification,
        object: nil
      )

      NotificationCenter.default.addObserver(
        self, selector: #selector(handleAudioRouteChange(_:)),
        name: AVAudioSession.routeChangeNotification, object: nil)
    #endif
  }

  private static let logger = OSLog(
    subsystem: "PlayolaPlayer",
    category: "PlayolaStationPlayer")

  private func getAvailableSpinPlayer() -> SpinPlayer {
    let availablePlayers = _spinPlayers.filter({ $0.state == .available })
    if let available = availablePlayers.first { return available }

    let newPlayer = SpinPlayer(delegate: self)
    _spinPlayers.append(newPlayer)
    return newPlayer
  }

  @MainActor
  private func scheduleSpin(spin: Spin, showProgress: Bool = false, retryCount: Int = 0)
    async throws
  {
    os_log(
      "📅 Scheduling spin: %@ - Retry: %d", log: PlayolaStationPlayer.logger, type: .info, spin.id,
      retryCount)

    let spinPlayer = getAvailableSpinPlayer()

    os_log("Using SpinPlayer for spin: %@", log: PlayolaStationPlayer.logger, type: .debug, spin.id)

    guard spin.audioBlock.downloadUrl != nil else {
      let spinDetails = """
            Spin ID: \(spin.id)
            Audio Block ID: \(spin.audioBlock.id)
            Audio Block Title: \(spin.audioBlock.title)
            Audio Block Artist: \(spin.audioBlock.artist)
            Download URL: \(spin.audioBlock.downloadUrl?.absoluteString ?? "nil")
        """
      let error = StationPlayerError.playbackError("Invalid audio file URL in spin")
      Task {
        await errorReporter.reportError(
          error,
          context: "Invalid or missing download URL for spin | \(spinDetails)",
          level: .error)
      }
      throw error
    }

    // Maximum retry attempts
    let maxRetries = 3

    // Cancel any existing download for this spin
    if let existingDownloadId = activeDownloadIds[spin.id] {
      _ = fileDownloadManager.cancelDownload(id: existingDownloadId)
      activeDownloadIds.removeValue(forKey: spin.id)
    }

    do {
      // Use new async API
      let result = await spinPlayer.load(
        spin,
        onDownloadProgress: { [weak self] progress in
          guard let self = self, showProgress else { return }
          self.state = .loading(progress)
        }
      )

      switch result {
      case .success:
        if showProgress {
          self.state = .playing(spin)
        }
        return
      case .failure(let error):
        // Check if this is a cancellation error - don't retry those
        if let urlError = error as? URLError, urlError.code == .cancelled {
          throw error
        }

        if let fileDownloadError = error as? FileDownloadError,
          case .downloadCancelled = fileDownloadError
        {
          throw error
        }

        // Handle file loading failure
        let stationError =
          error is FileDownloadError
          ? error
          : StationPlayerError.fileDownloadError(error.localizedDescription)

        Task {
          await self.errorReporter.reportError(stationError, level: .error)
        }

        // If we haven't exceeded retry attempts, try again
        if retryCount < maxRetries {
          // Add a small delay before retrying (exponential backoff)
          let delay = TimeInterval(0.5 * pow(2.0, Double(retryCount)))
          try await Task.sleep(for: .seconds(delay))
          try await self.scheduleSpin(
            spin: spin, showProgress: showProgress, retryCount: retryCount + 1)
        } else {
          throw error
        }
      }
    } catch {
      // Check if this is a cancellation error - don't retry those
      if let urlError = error as? URLError, urlError.code == .cancelled {
        throw error
      }

      if let fileDownloadError = error as? FileDownloadError,
        case .downloadCancelled = fileDownloadError
      {
        throw error
      }

      // If we haven't exceeded retry attempts, try again with exponential backoff
      if retryCount < maxRetries {
        let delay = TimeInterval(0.5 * pow(2.0, Double(retryCount)))
        try await Task.sleep(for: .seconds(delay))
        try await self.scheduleSpin(
          spin: spin, showProgress: showProgress, retryCount: retryCount + 1)
      } else {
        let stationError =
          error is StationPlayerError
          ? error
          : StationPlayerError.fileDownloadError(error.localizedDescription)
        Task {
          await errorReporter.reportError(stationError, level: .error)
        }
        throw error
      }
    }
  }

  @MainActor
  private func isScheduled(spin: Spin) -> Bool {
    return _spinPlayers.contains { $0.spin?.id == spin.id }
  }

  @MainActor
  private func scheduleUpcomingSpins() async {
    guard let stationId else {
      let error = StationPlayerError.invalidStationId("No station ID available")
      Task {
        await errorReporter.reportError(error, level: .warning)
      }
      return
    }

    do {
      // Check if task is cancelled before proceeding
      try Task.checkCancellation()

      let updatedSchedule = try await getUpdatedSchedule(stationId: stationId)

      // Log how many spins are in the updated schedule
      os_log(
        "Retrieved schedule: %d total, %d current", log: PlayolaStationPlayer.logger, type: .info,
        updatedSchedule.spins.count,
        updatedSchedule.current(offsetTimeInterval: scheduleOffset).count)

      // Extend the time window to load more upcoming spins (10 minutes instead of 6)
      let spinsToLoad = updatedSchedule.current(offsetTimeInterval: scheduleOffset).filter {
        $0.airtime < .now + TimeInterval(600)
      }

      os_log(
        "Loading %d upcoming spins", log: PlayolaStationPlayer.logger, type: .info,
        spinsToLoad.count)

      for spin in spinsToLoad {
        // Check cancellation before each spin
        try Task.checkCancellation()

        if !isScheduled(spin: spin) {
          os_log(
            "Scheduling new spin: %@ at %@", log: PlayolaStationPlayer.logger, type: .info, spin.id,
            ISO8601DateFormatter().string(from: spin.airtime))
          try await scheduleSpin(spin: spin)
        }
      }

      // Log already scheduled spins
      let scheduledSpinsCount = _spinPlayers.filter { $0.spin != nil }.count
      os_log(
        "Total scheduled spins: %d", log: PlayolaStationPlayer.logger, type: .info,
        scheduledSpinsCount)

    } catch {
      // Check if this was a cancellation
      if error is CancellationError {
        os_log("📛 Schedule update cancelled", log: PlayolaStationPlayer.logger, type: .info)
      } else {
        Task {
          await errorReporter.reportError(
            error, context: "Failed to schedule upcoming spins", level: .error)
        }

        // Log more details about the error
        os_log(
          "Schedule update failed: %@", log: PlayolaStationPlayer.logger, type: .error,
          error.localizedDescription)
      }
    }
  }

  private func getUpdatedSchedule(stationId: String) async throws -> Schedule {
    let url = baseUrl.appending(path: "/stations/\(stationId)/schedule")
      .appending(queryItems: [URLQueryItem(name: "includeRelatedTexts", value: "true")])
    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      guard let httpResponse = response as? HTTPURLResponse else {
        let error = StationPlayerError.networkError("Invalid response type")
        Task {
          await errorReporter.reportError(
            error,
            context: "Non-HTTP response received from schedule endpoint: \(url.absoluteString)",
            level: .error)
        }
        throw error
      }

      guard (200...299).contains(httpResponse.statusCode) else {
        let responseText = String(data: data, encoding: .utf8) ?? "Unable to decode response"
        let error = StationPlayerError.networkError("HTTP error: \(httpResponse.statusCode)")

        if httpResponse.statusCode == 404 {
          Task {
            await errorReporter.reportError(
              error,
              context: "Station not found: \(stationId) | Response: \(responseText.prefix(100))",
              level: .error)
          }
        } else {
          Task {
            await errorReporter.reportError(
              error,
              context:
                "HTTP \(httpResponse.statusCode) error getting schedule for station: \(stationId) | Response: \(responseText.prefix(100))",
              level: .error)
          }
        }
        throw error
      }

      let decoder = JSONDecoderWithIsoFull()

      do {
        let spins = try decoder.decode([Spin].self, from: data)
        guard !spins.isEmpty else {
          let error = StationPlayerError.scheduleError(
            "No spins returned in schedule for station ID: \(stationId)")
          Task {
            await errorReporter.reportError(error, level: .error)
          }
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

        Task {
          await errorReporter.reportError(
            decodingError, context: "Failed to decode schedule: \(context)", level: .error)
        }
        throw StationPlayerError.scheduleError("Invalid schedule data: \(context)")
      }
    } catch {
      Task {
        await errorReporter.reportError(
          error, context: "Failed to fetch schedule for station: \(stationId)", level: .error)
      }
      throw error
    }
  }

  /// Begins playback of the specified Playola station.
  ///
  /// This method:
  /// 1. Fetches the station's schedule from the Playola API
  /// 2. Loads and prepares the current audio block for playback
  /// 3. Schedules upcoming audio blocks to ensure smooth transitions
  /// 4. Reports the listening session to Playola analytics
  ///
  /// - Parameters:
  ///   - stationId: The unique identifier of the station to play
  ///   - atDate: Optional date to play from. If provided, the station will play as if it were that date/time.
  ///             For example, passing a date 1 hour ago will play the station from 1 hour ago.
  /// - Throws: `StationPlayerError` if playback cannot be started due to:
  ///   - Network errors when fetching the schedule
  ///   - Invalid station ID
  ///   - Missing audio content in the schedule
  ///   - File download failures
  public func play(stationId: String, atDate: Date? = nil) async throws {
    // Cancel any existing play task
    playTask?.cancel()

    // Calculate schedule offset if atDate is provided
    self.scheduleOffset = atDate?.timeIntervalSinceNow

    self.stationId = stationId

    // Get the schedule
    self.currentSchedule = try await getUpdatedSchedule(stationId: stationId)

    guard let spinToPlay = currentSchedule?.current(offsetTimeInterval: scheduleOffset).first else {
      let error = StationPlayerError.scheduleError("No available spins to play")
      Task {
        await errorReporter.reportError(
          error,
          context:
            "Schedule for station \(stationId) contains no current spins | Total spins: \(currentSchedule?.spins.count ?? 0)",
          level: .error)
      }
      throw error
    }

    // Log success with context
    os_log(
      "Starting playback for station: %@", log: PlayolaStationPlayer.logger, type: .info, stationId)

    // Schedule the first spin with progress shown
    try await scheduleSpin(spin: spinToPlay, showProgress: true)

    // Schedule upcoming spins
    schedulingTask?.cancel()
    schedulingTask = Task {
      await scheduleUpcomingSpins()
    }
  }

  /// Stops the current playback and releases associated resources.
  ///
  /// This method:
  /// 1. Stops all playing audio
  /// 2. Cancels pending downloads
  /// 3. Clears the current schedule
  /// 4. Reports the end of the listening session
  public func stop() {
    os_log("🛑 STOP called", log: PlayolaStationPlayer.logger, type: .info)

    // Log current state before stopping
    os_log(
      "Current state: %d players, %d downloads", log: PlayolaStationPlayer.logger, type: .info,
      _spinPlayers.count, activeDownloadIds.count)

    // Cancel any active async tasks first
    if schedulingTask != nil {
      os_log("Cancelling scheduling task", log: PlayolaStationPlayer.logger, type: .info)
      schedulingTask?.cancel()
      schedulingTask = nil
    }

    if playTask != nil {
      os_log("Cancelling play task", log: PlayolaStationPlayer.logger, type: .info)
      playTask?.cancel()
      playTask = nil
    }

    // Stop all players (this will cancel their individual downloads)
    os_log("Stopping %d players", log: PlayolaStationPlayer.logger, type: .info, _spinPlayers.count)

    for (index, player) in _spinPlayers.enumerated() {
      os_log(
        "Stopping player %d/%d", log: PlayolaStationPlayer.logger, type: .info, index + 1,
        _spinPlayers.count)
      player.stop()
    }

    // Cancel any downloads tracked at this level
    os_log(
      "Cancelling %d downloads", log: PlayolaStationPlayer.logger, type: .info,
      activeDownloadIds.count)

    for (spinId, downloadId) in activeDownloadIds {
      os_log("Cancelling download: %@", log: PlayolaStationPlayer.logger, type: .info, spinId)
      _ = fileDownloadManager.cancelDownload(id: downloadId)
    }
    activeDownloadIds.removeAll()

    self.stationId = nil
    self.currentSchedule = nil
    self.state = .idle

    os_log("✅ STOP completed", log: PlayolaStationPlayer.logger, type: .info)
  }

  #if os(iOS)
    /// Handle audio route changes such as connecting/disconnecting headphones
    @objc public func handleAudioRouteChange(_ notification: Notification) {
      guard let userInfo = notification.userInfo,
        let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
      else {
        return
      }

      // Check if the audio route changed
      switch reason {
      case .newDeviceAvailable:
        // New device (like headphones) was connected
        os_log("New audio route device available", log: PlayolaStationPlayer.logger, type: .info)

      case .oldDeviceUnavailable:
        // Old device (like headphones) was disconnected
        // You might want to pause playback here
        os_log("Audio route device disconnected", log: PlayolaStationPlayer.logger, type: .info)

      default:
        // Handle other route changes if needed
        os_log(
          "Audio route changed for reason: %d", log: PlayolaStationPlayer.logger, type: .info,
          reasonValue)
      }
    }

    /// Handle audio session interruptions such as phone calls
    @objc public func handleAudioSessionInterruption(_ notification: Notification) {
      guard let userInfo = notification.userInfo,
        let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else {
        return
      }

      switch type {
      case .began:
        // Audio session was interrupted - might need to pause playback
        os_log("Audio session interrupted", log: PlayolaStationPlayer.logger, type: .info)
        self.interruptedStationId = stationId
        stop()

      case .ended:
        // Interruption ended - might need to resume playback
        guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
          return
        }
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

        if options.contains(.shouldResume) {
          // The system indicates that we can resume audio
          if let interruptedStationId {
            Task { @MainActor [interruptedStationId] in
              try? await self.play(stationId: interruptedStationId)
            }
            self.interruptedStationId = nil
          }
        }

      @unknown default:
        os_log(
          "Unknown audio session interruption type: %d", log: PlayolaStationPlayer.logger,
          type: .error, typeValue)
      }
    }
  #endif

  deinit {
    fileDownloadManager.cancelAllDownloads()
  }
}

extension PlayolaStationPlayer: SpinPlayerDelegate {
  public func player(_ player: SpinPlayer, startedPlaying spin: Spin) {
    os_log("Started playing: %@", log: PlayolaStationPlayer.logger, type: .info, spin.id)

    self.state = .playing(spin)

    schedulingTask?.cancel()
    schedulingTask = Task {
      do {
        await self.scheduleUpcomingSpins()

        // Get a list of active file paths to exclude from pruning
        let activePaths = self._spinPlayers
          .compactMap { $0.localUrl?.path }

        // Use the new pruning method with proper error handling
        try self.fileDownloadManager.pruneCache(maxSize: nil, excludeFilepaths: activePaths)
      } catch {
        Task {
          await errorReporter.reportError(
            error, context: "Error during cache pruning after starting playback", level: .warning)
        }
      }
    }
  }

  nonisolated public func player(
    _ player: SpinPlayer,
    didPlayFile file: AVAudioFile,
    atTime time: TimeInterval,
    withBuffer buffer: AVAudioPCMBuffer
  ) {
  }

  public func player(_ player: SpinPlayer, didChangeState state: SpinPlayer.State) {
    os_log(
      "Player state: %@", log: PlayolaStationPlayer.logger, type: .info, String(describing: state))
  }
}

public protocol PlayolaStationPlayerDelegate: AnyObject {
  func player(
    _ player: PlayolaStationPlayer,
    playerStateDidChange state: PlayolaStationPlayer.State)
}
