import AVFoundation
import Combine
import Foundation
import PlayolaCore
import os.log

/// Delegate for StreamingSpinPlayer events.
@MainActor
protocol StreamingSpinPlayerDelegate: AnyObject {
  func streamingPlayer(_ player: StreamingSpinPlayer, startedPlaying spin: Spin)
  func streamingPlayer(
    _ player: StreamingSpinPlayer, didChangeState state: StreamingSpinPlayer.State)
  func streamingPlayer(_ player: StreamingSpinPlayer, didEncounterError error: Error)
}

/// Handles playback of a single spin using AVPlayer for streaming.
///
/// ```
/// State Machine:
///   ┌───────────┐   load()   ┌──────────┐  readyToPlay   ┌────────┐
///   │ available ├───────────►│ loading  ├───preroll()───►│ loaded │
///   └─────▲─────┘            └────┬─────┘                └───┬────┘
///         │                       │ .failed                   │ setRate/play
///         │                       ▼                           ▼
///         │                  ┌─────────┐              ┌──────────┐
///         │                  │  error  │              │ playing  │
///         │                  └─────────┘              └────┬─────┘
///         │                                                │ endtime+1s
///         │              clear()                           ▼
///         └────────────────────────────────────────── finished
/// ```
@MainActor
public class StreamingSpinPlayer {
  public enum State: Equatable {
    case available
    case loading
    case loaded
    case playing
    case finished
    case error
  }

  private static let logger = OSLog(
    subsystem: "PlayolaPlayer",
    category: "StreamingSpinPlayer")

  private static let cleanupBufferTime: TimeInterval = 1.0

  // MARK: - Public Properties
  let id = UUID()
  var spin: Spin?
  weak var delegate: StreamingSpinPlayerDelegate?

  public var state: State = .available {
    didSet {
      if oldValue != state {
        delegate?.streamingPlayer(self, didChangeState: state)
      }
    }
  }

  // MARK: - Audio
  private var avPlayer: AVPlayerProviding?

  // MARK: - Fade Automation
  private(set) var fadeSchedule: [FadeStep] = []
  private(set) var nextFadeIndex: Int = 0
  private var boundaryObserverToken: Any?

  // MARK: - Preroll
  private(set) var isPrerolled: Bool = false
  private var prerollHealthCheckTimer: Timer?
  private static let prerollHealthCheckLeadTime: TimeInterval = 30.0

  // MARK: - Scheduling Timers
  private var playTimer: Timer?
  private var clearTimer: Timer?

  // MARK: - Dependencies
  private let errorReporter = PlayolaErrorReporter.shared
  private let playerFactory: () -> AVPlayerProviding

  // MARK: - Playback State
  private var playbackStartOffsetMS: Int = 0

  // MARK: - Lifecycle

  init(
    delegate: StreamingSpinPlayerDelegate? = nil,
    playerFactory: (() -> AVPlayerProviding)? = nil
  ) {
    self.delegate = delegate
    self.playerFactory = playerFactory ?? { AVPlayerWrapper() }
  }

  // MARK: - Loading

  /// Loads a spin for streaming playback.
  ///
  /// Creates an AVPlayer with the spin's download URL and waits for the player
  /// to report readyToPlay status.
  func load(_ spin: Spin) async -> Result<Void, Error> {
    os_log(
      "Loading spin: %@", log: StreamingSpinPlayer.logger, type: .info, spin.id)

    guard let audioFileUrl = spin.audioBlock.downloadUrl else {
      let error = StationPlayerError.playbackError("Invalid audio file URL in spin")
      Task {
        await errorReporter.reportError(error, context: "Missing download URL", level: .error)
      }
      self.state = .available
      return .failure(error)
    }

    self.state = .loading
    self.spin = spin

    // Build fade schedule while player buffers
    self.fadeSchedule = FadeScheduleBuilder.buildFadeSchedule(for: spin)

    let player = playerFactory()
    self.avPlayer = player

    do {
      try await player.loadURL(audioFileUrl)
      os_log(
        "Player ready for spin: %@",
        log: StreamingSpinPlayer.logger, type: .info, spin.id)

      setupStallCallbacks(player: player)

      self.isPrerolled = await player.preroll(atRate: 1.0)
      os_log(
        "Preroll %@ for spin: %@",
        log: StreamingSpinPlayer.logger, type: .info,
        isPrerolled ? "succeeded" : "failed", spin.id)

      self.state = .loaded
      return .success(())
    } catch {
      os_log(
        "Player failed for spin: %@ - %@",
        log: StreamingSpinPlayer.logger, type: .error,
        spin.id, error.localizedDescription)
      Task {
        await self.errorReporter.reportError(
          error, context: "AVPlayerItem failed to load", level: .error)
      }
      self.state = .error
      return .failure(error)
    }
  }

  // MARK: - Playback

  /// Plays the loaded spin immediately from the specified position (in seconds).
  func playNow(from offsetSeconds: Double) {
    guard let avPlayer, state == .loaded || state == .playing else {
      os_log(
        "Cannot playNow - not loaded (state: %@)",
        log: StreamingSpinPlayer.logger, type: .info,
        String(describing: state))
      return
    }

    guard let spin else { return }

    let offsetMS = Int(offsetSeconds * 1000)

    // If past endOfMessage, skip
    if offsetMS >= spin.audioBlock.endOfMessageMS {
      os_log(
        "Offset %d past endOfMessage %d - skipping",
        log: StreamingSpinPlayer.logger, type: .info,
        offsetMS, spin.audioBlock.endOfMessageMS)
      clear()
      return
    }

    self.playbackStartOffsetMS = offsetMS

    // Set volume from fade schedule at current position
    let volume = FadeScheduleBuilder.volumeAtMS(
      offsetMS, in: fadeSchedule, startingVolume: spin.startingVolume)
    avPlayer.volume = volume

    // Seek to position and play
    let seekTime = CMTime(seconds: offsetSeconds, preferredTimescale: 600)
    Task { [weak self] in
      guard let self else { return }
      _ = await avPlayer.seek(to: seekTime)

      // Guard against clear() called during the await
      guard self.state == .loaded || self.state == .playing else { return }

      avPlayer.setRate(
        1.0, time: seekTime,
        atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
      self.state = .playing
      delegate?.streamingPlayer(self, startedPlaying: spin)

      // Start fade automation from the right index
      nextFadeIndex = FadeScheduleBuilder.firstUnprocessedIndex(
        in: fadeSchedule, afterMS: offsetMS)
      setupBoundaryFades()
      setupClearTimer()
    }
  }

  /// Schedules playback to start at a specific date (for future spins).
  func schedulePlay(at scheduledDate: Date) {
    guard state == .loaded else {
      os_log(
        "Cannot schedulePlay - not loaded (state: %@)",
        log: StreamingSpinPlayer.logger, type: .info,
        String(describing: state))
      return
    }

    guard let avPlayer, let spin else { return }

    os_log(
      "Scheduling play at %@ for spin: %@",
      log: StreamingSpinPlayer.logger, type: .info,
      ISO8601DateFormatter().string(from: scheduledDate), spin.id)

    // Set initial volume
    avPlayer.volume = spin.startingVolume
    self.playbackStartOffsetMS = 0

    if isPrerolled {
      schedulePlayWithHostTime(at: scheduledDate, avPlayer: avPlayer, spin: spin)
    } else {
      schedulePlayWithTimer(at: scheduledDate, avPlayer: avPlayer, spin: spin)
    }
  }

  private func schedulePlayWithHostTime(
    at scheduledDate: Date, avPlayer: AVPlayerProviding, spin: Spin
  ) {
    let delta = scheduledDate.timeIntervalSince(Date())

    if delta > 0 {
      let hostTimeNow = CMClockGetTime(CMClockGetHostTimeClock())
      let hostTimeAtAirtime = CMTimeAdd(
        hostTimeNow,
        CMTimeMakeWithSeconds(delta, preferredTimescale: 1_000_000))
      avPlayer.setRate(1.0, time: .zero, atHostTime: hostTimeAtAirtime)
    } else {
      avPlayer.play()
    }

    setupPlaybackStartObserver(avPlayer: avPlayer, spin: spin)
    self.nextFadeIndex = 0
    setupBoundaryFades()
    setupClearTimer()
    setupPrerollHealthCheck(for: scheduledDate)
  }

  private func schedulePlayWithTimer(
    at scheduledDate: Date, avPlayer: AVPlayerProviding, spin: Spin
  ) {
    os_log(
      "Preroll failed — falling back to Timer for spin: %@",
      log: StreamingSpinPlayer.logger, type: .info, spin.id)

    self.playTimer = Timer(
      fire: scheduledDate,
      interval: 0,
      repeats: false
    ) { [weak self] timer in
      timer.invalidate()
      guard let self else { return }

      Task { @MainActor in
        guard self.playTimer === timer, let avPlayer = self.avPlayer, let spin = self.spin else {
          return
        }

        avPlayer.play()
        self.state = .playing
        self.delegate?.streamingPlayer(self, startedPlaying: spin)
        self.nextFadeIndex = 0
        self.setupBoundaryFades()
        self.setupClearTimer()
      }
    }

    RunLoop.main.add(self.playTimer!, forMode: .default)
  }

  private func setupPlaybackStartObserver(avPlayer: AVPlayerProviding, spin: Spin) {
    let startTime = NSValue(
      time: CMTimeMakeWithSeconds(0.001, preferredTimescale: 1_000_000))

    let token = avPlayer.addBoundaryTimeObserver(
      forTimes: [startTime],
      queue: .main
    ) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.state == .loaded else { return }
        self.state = .playing
        self.delegate?.streamingPlayer(self, startedPlaying: spin)
      }
    }

    // Store as play timer token for cleanup — reuse playTimer cleanup path
    // We store in a dedicated property to avoid conflicts
    self.playbackStartObserverToken = token
  }

  private var playbackStartObserverToken: Any?

  private func removePlaybackStartObserver() {
    if let token = playbackStartObserverToken {
      avPlayer?.removeBoundaryTimeObserver(token)
      playbackStartObserverToken = nil
    }
  }

  // MARK: - Fade Automation (Boundary Observers)

  private func setupBoundaryFades() {
    removeBoundaryFadeObserver()
    guard let avPlayer, !fadeSchedule.isEmpty, nextFadeIndex < fadeSchedule.count else { return }

    let fadeTimes = fadeSchedule[nextFadeIndex...].map { step in
      NSValue(
        time: CMTimeMakeWithSeconds(Double(step.timeMS) / 1000.0, preferredTimescale: 1_000_000))
    }

    boundaryObserverToken = avPlayer.addBoundaryTimeObserver(
      forTimes: fadeTimes,
      queue: .main
    ) { [weak self] in
      Task { @MainActor [weak self] in
        self?.applyNextFadeStep()
      }
    }
  }

  private func applyNextFadeStep() {
    guard state == .playing || state == .loaded, let avPlayer else { return }

    let currentTimeMS = Int(avPlayer.currentTimeSeconds * 1000)
    let targetIndex = FadeScheduleBuilder.firstUnprocessedIndex(
      in: fadeSchedule, afterMS: currentTimeMS)

    if targetIndex > 0 {
      let step = fadeSchedule[targetIndex - 1]
      avPlayer.volume = step.volume
    }
    nextFadeIndex = targetIndex
  }

  private func removeBoundaryFadeObserver() {
    if let token = boundaryObserverToken {
      avPlayer?.removeBoundaryTimeObserver(token)
      boundaryObserverToken = nil
    }
  }

  // MARK: - Stall Recovery

  private func setupStallCallbacks(player: AVPlayerProviding) {
    player.onStall = { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        os_log(
          "Playback stalled for spin: %@",
          log: StreamingSpinPlayer.logger, type: .info,
          self.spin?.id ?? "nil")
      }
    }

    player.onUnstall = { [weak self] in
      Task { @MainActor [weak self] in
        guard let self,
          self.state == .playing || self.state == .loaded,
          let avPlayer = self.avPlayer
        else { return }
        os_log(
          "Playback recovered for spin: %@",
          log: StreamingSpinPlayer.logger, type: .info,
          self.spin?.id ?? "nil")
        avPlayer.play()
      }
    }
  }

  // MARK: - Preroll Health Check

  private func setupPrerollHealthCheck(for scheduledDate: Date) {
    let checkDate = scheduledDate.addingTimeInterval(
      -StreamingSpinPlayer.prerollHealthCheckLeadTime)

    guard checkDate > Date() else { return }

    prerollHealthCheckTimer = Timer(
      fire: checkDate,
      interval: 0,
      repeats: false
    ) { [weak self] timer in
      timer.invalidate()
      guard let self else { return }

      Task { @MainActor in
        guard self.prerollHealthCheckTimer === timer,
          let avPlayer = self.avPlayer,
          self.state == .loaded
        else { return }

        let rePrerolled = await avPlayer.preroll(atRate: 1.0)
        self.isPrerolled = rePrerolled
        os_log(
          "Health check re-preroll %@",
          log: StreamingSpinPlayer.logger, type: .info,
          rePrerolled ? "succeeded" : "failed")
      }
    }

    RunLoop.main.add(prerollHealthCheckTimer!, forMode: .default)
  }

  // MARK: - Clear Timer

  private func setupClearTimer() {
    guard let spin else { return }

    clearTimer = Timer(
      fire: spin.endtime.addingTimeInterval(StreamingSpinPlayer.cleanupBufferTime),
      interval: 0,
      repeats: false
    ) { [weak self] timer in
      timer.invalidate()
      guard let self else { return }
      Task { @MainActor in
        guard self.clearTimer === timer else { return }
        self.clearTimer = nil
        self.state = .finished
        self.clear()
      }
    }

    RunLoop.main.add(clearTimer!, forMode: .default)
  }

  // MARK: - Cleanup

  func stop() {
    os_log(
      "StreamingSpinPlayer.stop() - ID: %@, spin: %@",
      log: StreamingSpinPlayer.logger, type: .info,
      id.uuidString, spin?.id ?? "nil")
    clear()
  }

  func clear() {
    removeBoundaryFadeObserver()
    removePlaybackStartObserver()

    avPlayer?.cancelPendingPrerolls()
    avPlayer?.pause()
    avPlayer?.clearItem()
    avPlayer = nil

    playTimer?.invalidate()
    playTimer = nil

    clearTimer?.invalidate()
    clearTimer = nil

    prerollHealthCheckTimer?.invalidate()
    prerollHealthCheckTimer = nil

    fadeSchedule = []
    nextFadeIndex = 0
    playbackStartOffsetMS = 0
    isPrerolled = false

    spin = nil
    state = .available
  }
}
