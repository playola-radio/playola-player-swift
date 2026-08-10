//
//  PlayolaPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
// swiftlint:disable file_length
import AVFAudio
import Combine
import Foundation
@_exported import PlayolaCore
import os.log

/// Errors specific to the station player
public enum StationPlayerError: Error, LocalizedError, Sendable {
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

/// Selects the SDK's audio render backend (Phase 5). `.legacyEngine` is the proven per-spin
/// `AVAudioEngine` graph (the default); `.sampleBuffer` is the custom software mixer →
/// `AVSampleBufferAudioRenderer` path that casts AirPlay-2 long-form. Chosen via
/// `configure(renderBackend:)`, set once before first `play()` and locked thereafter.
public enum PlayolaRenderBackend: Sendable, Equatable {
  case legacyEngine
  case sampleBuffer
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
  var baseUrl = URL(string: "https://admin-api.playola.fm")!
  @Published public var stationId: String?
  private var interruptedStationId: String?
  var currentSchedule: Schedule?
  let fileDownloadManager: FileDownloadManaging
  var listeningSessionReporter: ListeningSessionReporter?
  private let errorReporter = PlayolaErrorReporter.shared
  private var authProvider: PlayolaAuthenticationProvider?
  private let urlSession: URLSessionProtocol
  /// Resolved lazily so merely constructing a station player (e.g. in headless
  /// macOS test runs) does not build the shared CoreAudio graph. The SDK touches
  /// the mixer only when playback actually starts (or resumes).
  var mainMixer: PlayolaMainMixer { .shared }

  /// Base delay (seconds) for the initial schedule-fetch exponential backoff.
  /// Internal so tests can disable the wait; not part of the public API.
  var scheduleRetryBaseDelay: TimeInterval = 0.5

  /// Time offset for playing station from a different point in time
  private var scheduleOffset: TimeInterval?

  private var activeDownloadIds: [String: UUID] = [:]

  // Internal (not private) so tests can observe scheduling-task lifecycle.
  var schedulingTask: Task<Void, Never>?

  // Monotonic token identifying the current play() attempt. Bumped on every
  // play() and stop(). Work started by an older generation — a prior session's
  // scheduling loop, or a spin whose audio starts after a newer attempt began —
  // must not publish state into the current generation. Internal for tests.
  var playGeneration: Int = 0

  /// Whether work tagged with `generation` belongs to the current play attempt.
  /// The gate that stops a superseded session from publishing state. Internal
  /// so tests can assert it without constructing a CoreAudio-backed SpinPlayer.
  func isCurrentGeneration(_ generation: Int) -> Bool {
    generation == playGeneration
  }

  // Audio interruption state
  private var isSuspended = false
  private var wasPlayingBeforeInterruption = false

  public weak var delegate: PlayolaStationPlayerDelegate?

  /// Active sample-buffer playback (Phase 5). Non-nil only while the `.sampleBuffer` backend is playing;
  /// the legacy `.legacyEngine` path leaves this nil and uses `_spinPlayers` exactly as before.
  private var sampleBufferController: SampleBufferPlaybackController?

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
  ///
  /// The SDK does not own the `AVAudioSession`. The host app must configure and
  /// activate it (category `.playback`) before calling `play(stationId:)` or
  /// `resumeAfterInterruption()`, and owns all interruption/route-change policy.
  /// See the README "Audio session" section.
  ///   - renderBackend: Which audio render path to use (Phase 5). Defaults to the proven
  ///     `.legacyEngine`. Set this once, before the first `play()`; it is locked afterward (a later
  ///     change is a release-mode no-op — see `setRenderBackend`). The app flips it to `.sampleBuffer`
  ///     behind a server flag.
  public func configure(
    authProvider: PlayolaAuthenticationProvider,
    baseURL: URL = URL(string: "https://admin-api.playola.fm")!,
    renderBackend: PlayolaRenderBackend = .legacyEngine
  ) {
    self.authProvider = authProvider
    self.listeningSessionReporter = ListeningSessionReporter(
      stationPlayer: self, authProvider: authProvider, baseURL: baseURL)
    self.baseUrl = baseURL
    setRenderBackend(renderBackend)
  }

  /// The active render backend (Phase 5). Defaults to `.legacyEngine`; locked after first `play()`.
  /// `private(set)` so tests in the module can read it.
  private(set) var renderBackend: PlayolaRenderBackend = .legacyEngine
  /// Set once playback has begun; further backend changes are ignored (release-mode no-op, [C5]).
  private var renderBackendLocked = false

  /// Whether the render backend is locked (playback has started). A UI selecting the backend should
  /// disable itself once this is true — `setRenderBackend` is a no-op thereafter.
  public var isRenderBackendLocked: Bool { renderBackendLocked }

  /// Selects the render backend (Phase 5). A no-op once playback has started (avoids an accidental
  /// mid-session switch on the pervasively-shared `.shared` instance). Instance-scoped so the same
  /// mechanism works on `.shared` now and on any future app-owned instance (eng-review A3).
  ///
  /// Use this when you configure auth elsewhere (or not at all); otherwise pass `renderBackend:` to
  /// `configure(authProvider:…)`. Set it BEFORE the first `play()`; to switch afterward, create a fresh
  /// player (or relaunch) — live switching is intentionally unsupported.
  public func setRenderBackend(_ backend: PlayolaRenderBackend) {
    // Real no-op once locked — in ALL build configs, not just an assertionFailure that vanishes in
    // release and would let the switch through (C5).
    guard !renderBackendLocked else { return }
    renderBackend = backend
  }

  /// Locks the render backend for the rest of this player's life. Called at the first `play()`.
  private func lockRenderBackend() {
    renderBackendLocked = true
  }

  /// Test seam: simulate the first-play lock without driving the network.
  func lockRenderBackendForTesting() {
    lockRenderBackend()
  }

  public enum State: Sendable {
    case loading(Float)
    case playing(Spin)
    case idle
    /// Emitted when a playback attempt fails terminally (e.g. the schedule
    /// fetch exhausted its retries). Lets consumers render a recoverable
    /// error instead of being stuck in a prior state.
    case error(StationPlayerError)
    /// Playback suspended by an interruption (host- or legacy-driven). The spin
    /// is the one that was playing at pause time — display metadata only; it
    /// will be re-fetched and re-synced on resume.
    case paused(Spin)
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
  internal init(
    fileDownloadManager: FileDownloadManaging? = nil,
    urlSession: URLSessionProtocol = PlayolaNetworkLoggingSession(
      wrapping: PlayolaTransport.apiSession)
  ) {
    self.fileDownloadManager = fileDownloadManager ?? FileDownloadManagerAsync.shared
    self.urlSession = urlSession
    self.authProvider = nil
    self.listeningSessionReporter = ListeningSessionReporter(stationPlayer: self, authProvider: nil)
    // The SDK does NOT observe AVAudioSession interruptions or route changes —
    // the host owns that policy and drives pauseForInterruption() /
    // resumeAfterInterruption() explicitly. It DOES self-recover its own engine
    // graph; that observer is registered lazily once playback begins (see
    // registerEngineConfigObserverIfNeeded()) so construction stays cheap.
  }

  /// True once the engine-config-change observer has been registered (lazily,
  /// on first playback) so we register it exactly once.
  private var engineConfigObserverRegistered = false
  private var engineConfigObserver: (any NSObjectProtocol)?

  /// Registers the AVAudioEngineConfigurationChange observer, scoped to the
  /// SDK's OWN engine. AVAudioEngine stops itself on a hardware/format/route
  /// reconfiguration and posts this notification; only the SDK can observe it
  /// for its own engine, so it must self-heal. This is engine ownership, not
  /// session ownership — it touches no AVAudioSession API.
  ///
  /// Registered lazily (from getAvailableSpinPlayer, at the moment a SpinPlayer
  /// resolves the shared mixer anyway) rather than at init, so merely
  /// constructing a player never builds the CoreAudio graph. Scoping to
  /// `mainMixer.engine` (not `object: nil`) means a host running its own
  /// AVAudioEngine does NOT trigger spurious SDK restarts.
  private func registerEngineConfigObserverIfNeeded() {
    guard !engineConfigObserverRegistered else { return }
    engineConfigObserverRegistered = true
    // Deliver on the main queue: AVAudioEngineConfigurationChange fires on an
    // unspecified thread, and the handler reads @MainActor state (isSuspended,
    // isPlaying, stationId, playGeneration) synchronously before hopping into a
    // Task. `queue: .main` guarantees those reads run on the main actor.
    engineConfigObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: mainMixer.engine,
      queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        self?.handleAudioEngineConfigurationChange(notification)
      }
    }
  }

  private static let logger = OSLog(
    subsystem: "PlayolaPlayer",
    category: "PlayolaStationPlayer")

  private func getAvailableSpinPlayer() -> SpinPlayer {
    let availablePlayers = _spinPlayers.filter({ $0.state == .available })
    if let available = availablePlayers.first { return available }

    // First real playback: the SpinPlayer below resolves the shared mixer, so
    // it's safe to scope the engine-recovery observer to that engine now.
    registerEngineConfigObserverIfNeeded()
    // Note: SpinPlayer currently couples to PlayolaMainMixer.shared internally
    // (it ignores an injected mixer). Fine in production where everything uses
    // .shared; threading injection through SpinPlayer is a known follow-up.
    let newPlayer = SpinPlayer(delegate: self)
    _spinPlayers.append(newPlayer)
    return newPlayer
  }

  @MainActor
  private func scheduleSpin(
    spin: Spin, generation: Int, showProgress: Bool = false, retryCount: Int = 0
  )
    async throws
  {
    os_log(
      "📅 Scheduling spin: %@ - Retry: %d", log: PlayolaStationPlayer.logger, type: .info, spin.id,
      retryCount)

    try validateSpinForScheduling(spin)
    // The generation is threaded in from the caller (play() or the scheduling
    // loop), not re-read from the mutable global, so a caller that has already
    // been superseded can't tag a player as the current attempt.
    let spinPlayer = getAvailableSpinPlayer()
    spinPlayer.playGeneration = generation
    cancelExistingDownload(for: spin.id)

    do {
      let result = await loadSpinWithProgress(spin, spinPlayer, generation, showProgress)
      try await handleLoadResult(
        result, spin: spin, generation: generation, showProgress: showProgress,
        retryCount: retryCount)
    } catch {
      try await handleSchedulingError(
        error, spin: spin, generation: generation, showProgress: showProgress,
        retryCount: retryCount)
    }
  }

  private func validateSpinForScheduling(_ spin: Spin) throws {
    guard spin.audioBlock.downloadUrl != nil else {
      let error = StationPlayerError.playbackError("Invalid audio file URL in spin")
      let spinDetails = createSpinDetailsString(spin)
      Task {
        await errorReporter.reportError(
          error,
          context: "Invalid or missing download URL for spin | \(spinDetails)",
          level: .error)
      }
      throw error
    }
  }

  private func createSpinDetailsString(_ spin: Spin) -> String {
    return """
        Spin ID: \(spin.id)
        Audio Block ID: \(spin.audioBlock.id)
        Audio Block Title: \(spin.audioBlock.title)
        Audio Block Artist: \(spin.audioBlock.artist)
        Download URL: \(spin.audioBlock.downloadUrl?.absoluteString ?? "nil")
      """
  }

  private func cancelExistingDownload(for spinId: String) {
    if let existingDownloadId = activeDownloadIds[spinId] {
      _ = fileDownloadManager.cancelDownload(id: existingDownloadId)
      activeDownloadIds.removeValue(forKey: spinId)
    }
  }

  private func loadSpinWithProgress(
    _ spin: Spin, _ spinPlayer: SpinPlayer, _ generation: Int, _ showProgress: Bool
  ) async -> Result<URL, Error> {
    return await spinPlayer.load(
      spin,
      onDownloadProgress: { [weak self] progress in
        guard let self = self, showProgress, self.isCurrentGeneration(generation) else { return }
        self.state = .loading(progress)
      }
    )
  }

  private func handleLoadResult(
    _ result: Result<URL, Error>, spin: Spin, generation: Int, showProgress: Bool,
    retryCount: Int
  ) async throws {
    switch result {
    case .success:
      if showProgress, isCurrentGeneration(generation) {
        self.state = .playing(spin)
      }
    case .failure(let error):
      try await handleLoadFailure(
        error, spin: spin, generation: generation, showProgress: showProgress,
        retryCount: retryCount)
    }
  }

  private func handleLoadFailure(
    _ error: Error, spin: Spin, generation: Int, showProgress: Bool, retryCount: Int
  )
    async throws
  {
    if shouldSkipRetry(for: error) {
      throw error
    }

    let stationError = convertToStationError(error)
    Task {
      await self.errorReporter.reportError(stationError, level: .error)
    }

    try await retryIfPossible(
      spin: spin, generation: generation, showProgress: showProgress, retryCount: retryCount,
      fallbackError: error)
  }

  private func handleSchedulingError(
    _ error: Error, spin: Spin, generation: Int, showProgress: Bool, retryCount: Int
  ) async throws {
    if shouldSkipRetry(for: error) {
      throw error
    }

    try await retryIfPossible(
      spin: spin, generation: generation, showProgress: showProgress, retryCount: retryCount,
      fallbackError: error)
  }

  private func shouldSkipRetry(for error: Error) -> Bool {
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }
    if let fileDownloadError = error as? FileDownloadError,
      case .downloadCancelled = fileDownloadError
    {
      return true
    }
    return false
  }

  private func convertToStationError(_ error: Error) -> Error {
    return error is FileDownloadError
      ? error
      : StationPlayerError.fileDownloadError(error.localizedDescription)
  }

  private func retryIfPossible(
    spin: Spin, generation: Int, showProgress: Bool, retryCount: Int, fallbackError: Error
  ) async throws {
    let maxRetries = 3
    if retryCount < maxRetries {
      let delay = TimeInterval(0.5 * pow(2.0, Double(retryCount)))
      try await Task.sleep(for: .seconds(delay))
      // A newer play()/stop() superseded us during backoff — abandon the retry
      // rather than reviving a stale session's spin.
      guard isCurrentGeneration(generation) else { return }
      try await self.scheduleSpin(
        spin: spin, generation: generation, showProgress: showProgress, retryCount: retryCount + 1)
    } else {
      let finalError =
        fallbackError is StationPlayerError
        ? fallbackError
        : StationPlayerError.fileDownloadError(fallbackError.localizedDescription)
      Task {
        await errorReporter.reportError(finalError, level: .error)
      }
      throw fallbackError
    }
  }

  @MainActor
  private func isScheduled(spin: Spin) -> Bool {
    return _spinPlayers.contains { $0.spin?.id == spin.id }
  }

  private let schedulePollingInterval: UInt64 = 20_000_000_000  // 20 seconds in nanoseconds

  @MainActor
  private func scheduleUpcomingSpins(generation: Int) async {
    guard let stationId else {
      let error = StationPlayerError.invalidStationId("No station ID available")
      Task { await errorReporter.reportError(error, level: .warning) }
      return
    }

    // Stop as soon as a newer play()/stop() supersedes this loop, even if this
    // task hasn't hit a cooperative cancellation point yet.
    while !Task.isCancelled && generation == playGeneration {
      do {
        try await performScheduleUpdate(stationId: stationId, generation: generation)
      } catch is CancellationError {
        os_log("📛 Schedule update cancelled", log: PlayolaStationPlayer.logger, type: .info)
        return
      } catch {
        Task {
          await errorReporter.reportError(
            error, context: "Failed to schedule upcoming spins", level: .error)
        }
        os_log(
          "Schedule update failed: %@", log: PlayolaStationPlayer.logger, type: .error,
          error.localizedDescription)
      }

      do {
        try await Task.sleep(nanoseconds: schedulePollingInterval)
      } catch {
        return
      }
    }
  }

  @MainActor
  private func performScheduleUpdate(stationId: String, generation: Int) async throws {
    let updatedSchedule = try await getUpdatedSchedule(stationId: stationId)

    // A newer play()/stop() superseded this loop while the fetch was in flight —
    // don't schedule the old session's spins into the new attempt.
    guard isCurrentGeneration(generation) else { return }

    os_log(
      "Retrieved schedule: %d total, %d current", log: PlayolaStationPlayer.logger, type: .info,
      updatedSchedule.spins.count,
      updatedSchedule.current(offsetTimeInterval: scheduleOffset).count)

    // Server returns only locked-in spins via lockedIn=true param.
    // This filter is a client-side safety net to prevent scheduling spins too far out.
    let spinsToLoad = updatedSchedule.current(offsetTimeInterval: scheduleOffset).filter {
      $0.airtime < .now + TimeInterval(600)
    }

    os_log(
      "Loading %d upcoming spins", log: PlayolaStationPlayer.logger, type: .info,
      spinsToLoad.count)

    for spin in spinsToLoad {
      try Task.checkCancellation()
      // Re-check between spins: scheduleSpin awaits a download, during which a
      // newer attempt can supersede us.
      guard isCurrentGeneration(generation) else { return }
      if !isScheduled(spin: spin) {
        os_log(
          "Scheduling new spin: %@ at %@", log: PlayolaStationPlayer.logger, type: .info,
          spin.id, ISO8601DateFormatter().string(from: spin.airtime))
        try await scheduleSpin(spin: spin, generation: generation)
      }
    }

    let scheduledSpinsCount = _spinPlayers.filter { $0.spin != nil }.count
    os_log(
      "Total scheduled spins: %d", log: PlayolaStationPlayer.logger, type: .info,
      scheduledSpinsCount)
  }

  /// Internal classification so the retry layer can tell transient failures
  /// (5xx, connectivity) apart from permanent ones (4xx, decode errors)
  /// without widening the public error surface. `publicError` is what callers
  /// ultimately receive — the public error API is unchanged.
  private struct ClassifiedScheduleError: Error {
    let isTransient: Bool
    let publicError: Error
  }

  /// Fetches the schedule with bounded exponential backoff, retrying only
  /// transient failures (server 5xx and connectivity errors). Permanent
  /// failures (404, decode errors, empty schedules) fail fast. The error
  /// thrown to callers is the same public error a single fetch would throw.
  ///
  /// Intentionally `internal` (not `private`) for test access, matching
  /// `scheduleRetryBaseDelay`; not part of the public API.
  func getUpdatedScheduleWithRetry(stationId: String) async throws -> Schedule {
    let maxRetries = 3
    var attempt = 0
    while true {
      do {
        return try await fetchScheduleOnce(stationId: stationId)
      } catch let classified as ClassifiedScheduleError {
        guard classified.isTransient, attempt < maxRetries else {
          throw classified.publicError
        }
        let delay = scheduleRetryBaseDelay * pow(2.0, Double(attempt))
        if delay > 0 {
          try await Task.sleep(for: .seconds(delay))
        }
        attempt += 1
      }
    }
  }

  /// Single, non-retrying schedule fetch. Used directly by the polling loop;
  /// re-throws the public error so existing callers see an unchanged surface.
  private func getUpdatedSchedule(stationId: String) async throws -> Schedule {
    do {
      return try await fetchScheduleOnce(stationId: stationId)
    } catch let classified as ClassifiedScheduleError {
      throw classified.publicError
    }
  }

  private func fetchScheduleOnce(stationId: String) async throws -> Schedule {
    let url = createScheduleURL(for: stationId)

    do {
      let (data, response) = try await urlSession.data(for: PlayolaTransport.apiRequest(url: url))
      let httpResponse = try validateHTTPResponse(response, url: url)
      try await validateStatusCode(httpResponse, data: data, stationId: stationId)

      return try await decodeSchedule(from: data, stationId: stationId)
    } catch let classified as ClassifiedScheduleError {
      // HTTP-status failures are already reported once by validateStatusCode.
      throw classified
    } catch let stationError as StationPlayerError {
      // validateHTTPResponse and decodeSchedule already reported these once.
      throw classifyScheduleFetchError(stationError)
    } catch {
      // A cancellation (a routine stop() during an in-flight fetch) is not a
      // reportable failure — skip the production error event but still
      // propagate so the caller treats it as a cancellation, not an error.
      if !isCancellation(error) {
        // Raw transport error (e.g. URLError) — not reported by any inner step,
        // so report it here exactly once.
        await reportScheduleFetchError(error, stationId: stationId)
      }
      throw classifyScheduleFetchError(error)
    }
  }

  /// Connectivity-related `URLError`s that a retry can plausibly recover from.
  /// Non-connectivity failures (e.g. `.badURL`, `.unsupportedURL`) are permanent
  /// and must fail fast instead of burning the backoff budget.
  private static let retryableURLErrorCodes: Set<URLError.Code> = [
    .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
    .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable,
    .secureConnectionFailed,
  ]

  private func classifyScheduleFetchError(_ error: Error) -> ClassifiedScheduleError {
    if error is CancellationError {
      return ClassifiedScheduleError(isTransient: false, publicError: error)
    }
    if let urlError = error as? URLError {
      let isTransient = Self.retryableURLErrorCodes.contains(urlError.code)
      return ClassifiedScheduleError(isTransient: isTransient, publicError: error)
    }
    return ClassifiedScheduleError(isTransient: false, publicError: error)
  }

  private func createScheduleURL(for stationId: String) -> URL {
    return baseUrl.appending(path: "/v1/stations/\(stationId)/schedule")
      .appending(queryItems: [
        URLQueryItem(name: "includeRelatedTexts", value: "true"),
        URLQueryItem(name: "lockedIn", value: "true"),
      ])
  }

  private func validateHTTPResponse(_ response: URLResponse, url: URL) throws -> HTTPURLResponse {
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
    return httpResponse
  }

  private func validateStatusCode(_ httpResponse: HTTPURLResponse, data: Data, stationId: String)
    async throws
  {
    guard (200...299).contains(httpResponse.statusCode) else {
      let responseText = String(data: data, encoding: .utf8) ?? "Unable to decode response"
      let error = StationPlayerError.networkError("HTTP error: \(httpResponse.statusCode)")

      await reportHTTPError(
        error, statusCode: httpResponse.statusCode, stationId: stationId, responseText: responseText
      )
      throw ClassifiedScheduleError(
        isTransient: (500...599).contains(httpResponse.statusCode), publicError: error)
    }
  }

  private func reportHTTPError(
    _ error: StationPlayerError, statusCode: Int, stationId: String, responseText: String
  ) async {
    if statusCode == 404 {
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
            "HTTP \(statusCode) error getting schedule for station: \(stationId) | "
            + "Response: \(responseText.prefix(100))",
          level: .error)
      }
    }
  }

  private func decodeSchedule(from data: Data, stationId: String) async throws -> Schedule {
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
      let context = await reportDecodingError(decodingError)
      throw StationPlayerError.scheduleError("Invalid schedule data: \(context)")
    }
  }

  private func reportDecodingError(_ decodingError: DecodingError) async -> String {
    let context: String
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

    return context
  }

  private func reportScheduleFetchError(_ error: Error, stationId: String) async {
    Task {
      await errorReporter.reportError(
        error, context: "Failed to fetch schedule for station: \(stationId)", level: .error)
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
    // Lock the render backend on the first play() so it can't switch mid-session (Phase 5, A3/C5).
    lockRenderBackend()

    // Reset any stale interruption state when explicitly starting playback.
    // This ensures CarPlay and other external callers always get a clean start.
    isSuspended = false
    wasPlayingBeforeInterruption = false
    interruptedStationId = nil

    // Calculate schedule offset if atDate is provided
    self.scheduleOffset = atDate?.timeIntervalSinceNow

    self.stationId = stationId

    // Take over as the current play attempt. Any in-flight work from a prior
    // attempt (its scheduling loop, late spin callbacks) belongs to an older
    // generation and will no longer publish into state.
    playGeneration += 1
    let generation = playGeneration

    // Emit a terminal-trackable state from the start so consumers observing
    // $state always see the attempt begin and (below) its success or failure.
    self.state = .loading(0)

    do {
      // Get the schedule (with bounded backoff for transient outages)
      let schedule = try await getUpdatedScheduleWithRetry(stationId: stationId)

      // A newer play()/stop() superseded us mid-fetch — abandon quietly without
      // writing the stale schedule into the shared field we no longer own.
      guard generation == playGeneration else { return }
      self.currentSchedule = schedule

      guard
        let spinToPlay = currentSchedule?.current(offsetTimeInterval: scheduleOffset).first
      else {
        let error = StationPlayerError.scheduleError("No available spins to play")
        Task {
          await errorReporter.reportError(
            error,
            context:
              "Schedule for station \(stationId) contains no current spins | "
              + "Total spins: \(currentSchedule?.spins.count ?? 0)",
            level: .error)
        }
        throw error
      }

      // Log success with context
      os_log(
        "Starting playback for station: %@", log: PlayolaStationPlayer.logger, type: .info,
        stationId)

      // Phase 5: the sample-buffer backend drives its own pipeline (download -> decode -> mixer ->
      // AVSampleBufferAudioRenderer) instead of the legacy per-spin SpinPlayer graph. The wall-clock
      // schedule fetch/poll above is shared; only the render sink differs. Legacy path is untouched.
      if renderBackend == .sampleBuffer {
        startSampleBufferPlayback(generation: generation, firstSpin: spinToPlay)
        return
      }

      // Schedule the first spin with progress shown
      try await scheduleSpin(spin: spinToPlay, generation: generation, showProgress: true)

      // Superseded while loading the first spin — don't start a scheduling loop.
      guard generation == playGeneration else { return }

      // Take over the scheduling loop from any prior session and start our own.
      schedulingTask?.cancel()
      schedulingTask = Task { [generation] in
        await scheduleUpcomingSpins(generation: generation)
      }
    } catch {
      // Only publish the failure if we're still the current attempt. A newer
      // play()/stop() owns state now, and a prior session's still-running loop
      // is gated by generation rather than force-cancelled here (it would
      // otherwise tear down a live session this failed attempt never started).
      guard generation == playGeneration else { throw error }

      // Emit a terminal error state so consumers can render a recoverable
      // error instead of being stuck in .loading. Cancellation is not an error.
      if !isCancellation(error) {
        let stationError =
          (error as? StationPlayerError) ?? .scheduleError(error.localizedDescription)
        self.state = .error(stationError)
      }
      throw error
    }
  }

  // MARK: - Sample-buffer backend (Phase 5)

  /// Spins currently airing or due within the lookahead window, filtered as the legacy path does.
  private func sampleBufferSpins(from schedule: Schedule?) -> [Spin] {
    (schedule?.current(offsetTimeInterval: scheduleOffset) ?? []).filter {
      $0.airtime < .now + TimeInterval(600)
    }
  }

  /// Starts the sample-buffer render pipeline for the current schedule and begins polling for upcoming
  /// spins. The already-airing `firstSpin` is published immediately (its boundary is in the past);
  /// later spins publish `.playing` as their boundaries are crossed.
  private func startSampleBufferPlayback(generation: Int, firstSpin: Spin) {
    // A second play() (station switch) with no intervening stop() must tear the previous controller
    // down in order before replacing it — otherwise its renderer/pump can outlive ownership.
    teardownSampleBufferPlayback()

    let controller = SampleBufferPlaybackController(
      anchorDate: Date(),
      fileDownloadManager: fileDownloadManager)
    controller.onSpinStarted = { [weak self] spin in
      guard let self, self.isCurrentGeneration(generation) else { return }
      self.state = .playing(spin)
    }
    // Stay .loading until the first decode actually starts playback (§4.4), then publish the airing spin.
    controller.onPlaybackStarted = { [weak self] in
      guard let self, self.isCurrentGeneration(generation) else { return }
      self.state = .playing(firstSpin)
    }
    self.sampleBufferController = controller

    controller.start(with: sampleBufferSpins(from: currentSchedule))

    schedulingTask?.cancel()
    schedulingTask = Task { [generation] in
      await pollAndFeedSampleBuffer(generation: generation)
    }
  }

  /// Reuses the wall-clock 20s poll to feed newly-appeared upcoming spins into the running sample-buffer
  /// renderer (the controller de-dupes and appends beyond the enqueue horizon).
  private func pollAndFeedSampleBuffer(generation: Int) async {
    guard let stationId else { return }
    while !Task.isCancelled && generation == playGeneration {
      do {
        let updated = try await getUpdatedSchedule(stationId: stationId)
        guard isCurrentGeneration(generation) else { return }
        sampleBufferController?.addUpcoming(sampleBufferSpins(from: updated))
      } catch is CancellationError {
        return
      } catch {
        Task {
          await errorReporter.reportError(
            error, context: "Failed to poll schedule (sample-buffer)", level: .error)
        }
      }
      do {
        try await Task.sleep(nanoseconds: schedulePollingInterval)
      } catch {
        return
      }
    }
  }

  private func teardownSampleBufferPlayback() {
    sampleBufferController?.stop()
    sampleBufferController = nil
  }

  // Internal for testability. Kept consistent with `shouldSkipRetry`: a
  // cancelled in-flight download (thrown by scheduleSpin when stop() runs) is a
  // cancellation, not a terminal error, and must not flip state to .error.
  func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    if let fileDownloadError = error as? FileDownloadError,
      case .downloadCancelled = fileDownloadError
    {
      return true
    }
    return false
  }

  // MARK: - Internal test seams

  func setStateForTesting(_ state: State, stationId: String?) {
    self.state = state
    self.stationId = stationId
  }

  var isSuspendedForTesting: Bool { isSuspended }
  var interruptedStationIdForTesting: String? { interruptedStationId }
  var wasPlayingBeforeInterruptionForTesting: Bool { wasPlayingBeforeInterruption }

  /// Stops the current playback and releases associated resources.
  ///
  /// This method:
  /// 1. Stops all playing audio
  /// 2. Cancels pending downloads
  /// 3. Clears the current schedule
  /// 4. Goes `.idle`, which ends the listening session (the reporter observes
  ///    `state`, so a real stop ends reporting — backgrounding does not).
  public func stop() {
    os_log("🛑 STOP called", log: PlayolaStationPlayer.logger, type: .info)

    // Supersede any in-flight play()/scheduling work so it can't publish state
    // after we go idle.
    playGeneration += 1

    // Phase 5: tear down the sample-buffer pipeline if it was active (no-op for the legacy path).
    teardownSampleBufferPlayback()

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
    // stop() means "forget everything", including any armed interruption. Without
    // this, a later resumeAfterInterruption() (or a resume retry) could revive a
    // station the host explicitly stopped.
    self.isSuspended = false
    self.wasPlayingBeforeInterruption = false
    self.interruptedStationId = nil

    os_log("✅ STOP completed", log: PlayolaStationPlayer.logger, type: .info)
  }

  /// Host-driven interruption pause. Silences playback and cancels scheduling,
  /// preserving ONLY the station id; the schedule is wall-clock-stale by resume
  /// time, so resume re-fetches. Bumps playGeneration so in-flight work from
  /// before the pause cannot publish state after it.
  public func pauseForInterruption() {
    playGeneration += 1
    // Loading counts as "playing" for resume purposes: if the user started a
    // station and a call interrupts the load, they expect it back afterward.
    let wasActive: Bool = {
      switch state {
      case .playing, .loading: return true
      case .idle, .paused, .error: return false
      }
    }()
    // A repeated pause (e.g. interruption + route change for the same outage)
    // must not overwrite the armed resume state. Pausing while inactive arms
    // nothing — there is no playback to bring back.
    if !isSuspended {
      wasPlayingBeforeInterruption = wasActive
      interruptedStationId = wasActive ? stationId : nil
    }
    isSuspended = true
    schedulingTask?.cancel()
    schedulingTask = nil
    // Phase 5: tear down the sample-buffer pipeline if it was active (no-op for the legacy path).
    teardownSampleBufferPlayback()
    for player in _spinPlayers { player.stop() }
    for (_, downloadId) in activeDownloadIds {
      _ = fileDownloadManager.cancelDownload(id: downloadId)
    }
    activeDownloadIds.removeAll()
    switch state {
    case .playing(let spin): state = .paused(spin)
    case .loading: state = .idle  // no spin to show; resume re-fetches and republishes .loading
    default: break
    }
  }

  /// Host-driven resume. Restarts the engine and replays the interrupted station
  /// re-synced to the current wall clock. The host owns the `AVAudioSession` and
  /// MUST have re-activated it before calling this. No-op if nothing was
  /// interrupted OR if playback wasn't active when the pause happened.
  ///
  /// Consumes the interruption up-front: this is a one-shot attempt. On failure
  /// it both throws AND publishes `.error` state (so a host driving UI from
  /// `$state` sees the failure without catching the throw). **To retry, call
  /// `play(stationId:)`** — the station is available as the player's `stationId`
  /// (still set after a failed resume; only `stop()` clears it). The resume is
  /// abandoned cleanly if the host starts or stops playback while it's in flight.
  public func resumeAfterInterruption() async throws {
    guard let stationToResume = interruptedStationId,
      wasPlayingBeforeInterruption
    else { return }
    // Consume the armed interruption now — this attempt owns it. (play() would
    // clear these at its first lines anyway; clearing here keeps the failure
    // path honest: retry is via play(), not a second resume call.)
    isSuspended = false
    interruptedStationId = nil
    wasPlayingBeforeInterruption = false

    // restartEngine() before play(): after an interruption the engine may be in
    // a stopped-but-stale CoreAudio state; play()'s lazy engine start does not
    // re-prepare a torn-down graph. restartEngine() (stop+prepare+start) is
    // idempotent when healthy. The sample-buffer backend uses no AVAudioEngine, so
    // skip it there — an unrelated engine failure must not block a sample-buffer resume.
    let generation = playGeneration
    do {
      if renderBackend == .legacyEngine {
        try await mainMixer.restartEngine()
      }
    } catch {
      // Mirror play()'s error path so a host observing $state isn't left on a
      // stale .paused with no working resume — but only if a host stop()/play()
      // hasn't superseded us during the restart.
      if generation == playGeneration {
        state = .error(
          .playbackError("Failed to restart audio engine on resume: \(error.localizedDescription)"))
      }
      throw error
    }
    // A host stop()/play() during restartEngine bumped the generation — abandon
    // the resume so we don't revive a station the host stopped or override a
    // station it just started. (Supersession during play()'s own awaits is
    // handled by play()'s generation gate.)
    guard generation == playGeneration else { return }
    try await play(stationId: stationToResume)
  }

  /// Recovers the SDK's own engine graph when AVAudioEngine reconfigures itself
  /// (hardware/format/route change) and stops. This is engine ownership, not
  /// session ownership: it touches no AVAudioSession API. Skipped while the host
  /// has paused for an interruption (the host drives resume then). Only acts
  /// while actively playing; re-syncs to the live wall clock via play().
  ///
  /// Internal: delivered on the main queue from a block observer (see
  /// registerEngineConfigObserverIfNeeded), so it runs on the main actor. Not
  /// host API — the host never calls it.
  func handleAudioEngineConfigurationChange(_ notification: Notification) {
    os_log("Audio engine configuration changed", log: PlayolaStationPlayer.logger, type: .info)
    guard !isSuspended, isPlaying, let stationToRecover = stationId else { return }
    // Snapshot the recovery attempt: stationToRecover + generation together. Any
    // host stop()/play() after this point bumps playGeneration and invalidates
    // the recovery — we must not override the host's explicit choice (same
    // supersession discipline resumeAfterInterruption() uses).
    let generation = playGeneration
    Task { @MainActor in
      do {
        try await mainMixer.restartEngine()
      } catch {
        // Surface via state (mirrors resumeAfterInterruption) so a host driving
        // UI from $state isn't left on a stale .playing with dead audio — and
        // report — but only if a host stop()/play() hasn't superseded us during
        // the restart (a superseded recovery is moot; don't add Sentry noise).
        if generation == playGeneration {
          state = .error(
            .playbackError(
              "Failed to recover audio engine after configuration change: "
                + error.localizedDescription))
          await errorReporter.reportError(
            error, context: "Failed to recover engine after configuration change", level: .error)
        }
        return
      }
      // A host stop()/play() during restartEngine took over — don't override it.
      guard generation == playGeneration else { return }
      do {
        try await play(stationId: stationToRecover)
      } catch {
        // play() publishes .error itself on terminal failure when still current.
        await errorReporter.reportError(
          error, context: "Failed to recover engine after configuration change", level: .error)
      }
    }
  }

  deinit {
    fileDownloadManager.cancelAllDownloads()
  }
}

extension PlayolaStationPlayer: SpinPlayerDelegate {
  public func player(_ player: SpinPlayer, startedPlaying spin: Spin) {
    // Ignore callbacks from a superseded session — otherwise a spin scheduled by
    // a prior play() could flip a newer .loading/.error/.idle state to .playing.
    guard isCurrentGeneration(player.playGeneration) else {
      os_log(
        "Ignoring startedPlaying from superseded generation: %@",
        log: PlayolaStationPlayer.logger, type: .info, spin.id)
      return
    }

    os_log("Started playing: %@", log: PlayolaStationPlayer.logger, type: .info, spin.id)

    self.state = .playing(spin)

    schedulingTask?.cancel()
    schedulingTask = Task { [generation = playGeneration] in
      do {
        await self.scheduleUpcomingSpins(generation: generation)

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
// swiftlint:enable file_length
