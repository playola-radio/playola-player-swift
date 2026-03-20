import AVFoundation
import Combine
import Foundation
import PlayolaCore
import os.log

/// A streaming audio player for Playola stations using AVPlayer.
///
/// Unlike `PlayolaStationPlayer` which downloads entire files before playback,
/// `StreamingStationPlayer` streams audio via AVPlayer for faster startup.
///
/// ```
/// Lifecycle:
///   play(stationId:) → fetch schedule → load current spin → start playback
///                                     → poll every 20s for upcoming spins
///   stop()           → cancel tasks → stop all players → nil stationId
///
/// Spin Management:
///   spinPlayers: [String: StreamingSpinPlayer]  — keyed by spin ID
///   - Current spin: playNow(from: offset)
///   - Future spins: schedulePlay(at: airtime)
///   - Finished spins: cleared automatically via clearTimer
/// ```
@MainActor
final public class StreamingStationPlayer: ObservableObject {
  public enum State: Sendable {
    case loading
    case playing(Spin)
    case idle
  }

  private static let logger = OSLog(
    subsystem: "PlayolaPlayer",
    category: "StreamingStationPlayer")

  private static let schedulePollingInterval: TimeInterval = 20.0
  private static let scheduleWindow: TimeInterval = 600  // 10 minutes

  // MARK: - Public Properties

  @Published public var stationId: String?
  @Published public var state: StreamingStationPlayer.State = .idle

  public var isPlaying: Bool {
    switch state {
    case .playing: return true
    default: return false
    }
  }

  // MARK: - Dependencies

  var baseUrl = URL(string: "https://admin-api.playola.fm")!
  var listeningSessionReporter: ListeningSessionReporter?
  private let errorReporter = PlayolaErrorReporter.shared
  private var authProvider: PlayolaAuthenticationProvider?
  private let playerFactory: () -> AVPlayerProviding
  private let audioSessionManager = AudioSessionManager()

  // MARK: - Internal State

  var spinPlayers: [String: StreamingSpinPlayer] = [:]
  private var currentSchedule: Schedule?
  private var scheduleOffset: TimeInterval?
  private var schedulingTask: Task<Void, Never>?

  // Audio interruption state
  private var isSuspended = false
  private var wasPlayingBeforeInterruption = false
  private var interruptedStationId: String?

  // MARK: - Lifecycle

  public init(playerFactory: (() -> AVPlayerProviding)? = nil) {
    self.playerFactory = playerFactory ?? { AVPlayerWrapper() }

    #if os(iOS) || os(tvOS)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleAudioSessionInterruption(_:)),
        name: AVAudioSession.interruptionNotification,
        object: nil
      )

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleAudioRouteChange(_:)),
        name: AVAudioSession.routeChangeNotification,
        object: nil
      )
    #endif
  }

  /// Configure with authentication provider.
  public func configure(
    authProvider: PlayolaAuthenticationProvider,
    baseURL: URL = URL(string: "https://admin-api.playola.fm")!
  ) {
    self.authProvider = authProvider
    self.baseUrl = baseURL
    self.listeningSessionReporter = ListeningSessionReporter(
      stationIdPublisher: $stationId.eraseToAnyPublisher(),
      stationIdGetter: { [weak self] in self?.stationId },
      authProvider: authProvider,
      baseURL: baseURL
    )
  }

  // MARK: - Playback

  /// Begins streaming playback of the specified station.
  public func play(stationId: String, atDate: Date? = nil) async throws {
    isSuspended = false
    wasPlayingBeforeInterruption = false
    interruptedStationId = nil

    schedulingTask?.cancel()
    self.scheduleOffset = atDate?.timeIntervalSinceNow
    self.stationId = stationId
    self.state = .loading

    try await audioSessionManager.activate()

    let schedule = try await ScheduleService.getSchedule(
      stationId: stationId, baseUrl: baseUrl)
    self.currentSchedule = schedule

    let currentSpins = schedule.current(offsetTimeInterval: scheduleOffset)
    guard let firstSpin = currentSpins.first else {
      let error = StationPlayerError.scheduleError("No available spins to play")
      Task {
        await errorReporter.reportError(
          error,
          context: "Schedule for station \(stationId) contains no current spins | "
            + "Total spins: \(schedule.spins.count)",
          level: .error)
      }
      throw error
    }

    try await loadAndPlaySpin(firstSpin)

    schedulingTask = Task {
      await scheduleUpcomingSpins()
    }
  }

  /// Stops playback and releases resources.
  public func stop() {
    os_log("Stop called", log: StreamingStationPlayer.logger, type: .info)

    schedulingTask?.cancel()
    schedulingTask = nil

    for (_, player) in spinPlayers {
      player.stop()
    }
    spinPlayers.removeAll()

    self.stationId = nil
    self.currentSchedule = nil
    self.state = .idle
  }

  // MARK: - Spin Loading

  private func loadAndPlaySpin(_ spin: Spin) async throws {
    let player = getOrCreateSpinPlayer(for: spin)

    let result = await player.load(spin)
    switch result {
    case .success:
      let timing = spin.playbackTiming
      switch timing {
      case .playing:
        let elapsedSeconds = Date().timeIntervalSince(spin.airtime)
        player.playNow(from: elapsedSeconds)
        self.state = .playing(spin)
      case .future:
        player.schedulePlay(at: spin.airtime)
      case .tooLateToStart, .past:
        player.clear()
        spinPlayers.removeValue(forKey: spin.id)
      }
    case .failure(let error):
      spinPlayers.removeValue(forKey: spin.id)
      throw error
    }
  }

  private func getOrCreateSpinPlayer(for spin: Spin) -> StreamingSpinPlayer {
    if let existing = spinPlayers[spin.id] {
      return existing
    }
    let player = StreamingSpinPlayer(
      delegate: self,
      playerFactory: playerFactory
    )
    spinPlayers[spin.id] = player
    return player
  }

  // MARK: - Schedule Polling

  private func scheduleUpcomingSpins() async {
    guard let stationId else { return }

    while !Task.isCancelled {
      do {
        try await performScheduleUpdate(stationId: stationId)
      } catch is CancellationError {
        return
      } catch {
        os_log(
          "Schedule update failed: %@",
          log: StreamingStationPlayer.logger, type: .error,
          error.localizedDescription)
      }

      do {
        try await Task.sleep(for: .seconds(StreamingStationPlayer.schedulePollingInterval))
      } catch {
        return
      }
    }
  }

  private func performScheduleUpdate(stationId: String) async throws {
    let updatedSchedule = try await ScheduleService.getSchedule(
      stationId: stationId, baseUrl: baseUrl)

    let spinsToLoad = updatedSchedule.current(offsetTimeInterval: scheduleOffset).filter {
      $0.airtime < .now + StreamingStationPlayer.scheduleWindow
    }

    for spin in spinsToLoad {
      try Task.checkCancellation()
      if spinPlayers[spin.id] == nil {
        do {
          try await loadAndPlaySpin(spin)
        } catch {
          os_log(
            "Failed to load spin %@: %@",
            log: StreamingStationPlayer.logger, type: .error,
            spin.id, error.localizedDescription)
        }
      }
    }
  }

  // MARK: - Audio Interruptions

  #if os(iOS) || os(tvOS)
    @objc public func handleAudioRouteChange(_ notification: Notification) {
      guard let userInfo = notification.userInfo,
        let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
      else { return }

      switch reason {
      case .oldDeviceUnavailable:
        guard
          let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        else { return }

        let wasUsingHeadphones = previousRoute.outputs.contains {
          [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }

        if wasUsingHeadphones && isPlaying {
          interruptedStationId = stationId
          wasPlayingBeforeInterruption = true
          stop()
        }
      default:
        break
      }
    }

    @objc public func handleAudioSessionInterruption(_ notification: Notification) {
      guard let userInfo = notification.userInfo,
        let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }

      switch type {
      case .began:
        isSuspended = true
        wasPlayingBeforeInterruption = isPlaying
        interruptedStationId = stationId
        schedulingTask?.cancel()
        schedulingTask = nil

      case .ended:
        isSuspended = false
        guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
          return
        }
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
          resumeAfterInterruption()
        }

      @unknown default:
        break
      }
    }

    private func resumeAfterInterruption() {
      guard let stationToResume = interruptedStationId else { return }

      Task { @MainActor in
        do {
          try await self.audioSessionManager.activate()
          try await self.play(stationId: stationToResume)
        } catch {
          os_log(
            "Failed to resume after interruption: %@",
            log: StreamingStationPlayer.logger, type: .error,
            error.localizedDescription)
          await errorReporter.reportError(
            error, context: "Failed to resume playback after interruption", level: .error)
        }

        self.interruptedStationId = nil
        self.wasPlayingBeforeInterruption = false
      }
    }
  #endif
}

// MARK: - StreamingSpinPlayerDelegate

extension StreamingStationPlayer: StreamingSpinPlayerDelegate {
  func streamingPlayer(_ player: StreamingSpinPlayer, startedPlaying spin: Spin) {
    os_log(
      "Started playing: %@",
      log: StreamingStationPlayer.logger, type: .info, spin.id)
    self.state = .playing(spin)
  }

  func streamingPlayer(
    _ player: StreamingSpinPlayer, didChangeState state: StreamingSpinPlayer.State
  ) {
    if state == .finished {
      if let spinId = player.spin?.id ?? spinPlayers.first(where: { $0.value === player })?.key {
        spinPlayers.removeValue(forKey: spinId)
      }
    }
  }

  func streamingPlayer(_ player: StreamingSpinPlayer, didEncounterError error: Error) {
    os_log(
      "Spin player error: %@",
      log: StreamingStationPlayer.logger, type: .error,
      error.localizedDescription)
    Task {
      await errorReporter.reportError(error, context: "StreamingSpinPlayer error", level: .error)
    }
  }
}
