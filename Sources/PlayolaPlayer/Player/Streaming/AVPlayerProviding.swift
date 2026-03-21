import AVFoundation
import Foundation

/// Protocol wrapping AVPlayer for testability.
///
/// Follows the same pattern as URLSessionProtocol in the codebase.
/// In production, AVPlayer conforms via a wrapper. In tests, MockAVPlayer conforms.
@MainActor
public protocol AVPlayerProviding: AnyObject {
  var volume: Float { get set }
  var currentTimeSeconds: Double { get }
  func play()
  func pause()
  func seek(to time: CMTime) async -> Bool

  /// Loads a URL and waits until the player is ready to play.
  /// Throws if the item fails to load.
  func loadURL(_ url: URL) async throws

  /// Tears down the current item.
  func clearItem()

  /// Registers a boundary time observer that fires when playback crosses any of the given times.
  /// Returns `nil` if the player has no current item.
  func addBoundaryTimeObserver(
    forTimes times: [NSValue],
    queue: DispatchQueue?,
    using block: @escaping @Sendable () -> Void
  ) -> Any?

  /// Removes a previously registered boundary time observer.
  func removeBoundaryTimeObserver(_ token: Any)

  /// Pre-rolls the player at the given rate. Returns true if preroll succeeded.
  func preroll(atRate rate: Float) async -> Bool

  /// Cancels any pending preroll.
  func cancelPendingPrerolls()

  /// Starts playback at a specific item time synchronized to a host time.
  func setRate(_ rate: Float, time: CMTime, atHostTime hostTime: CMTime)

  /// Callback invoked when playback stalls due to empty buffer.
  var onStall: (() -> Void)? { get set }

  /// Callback invoked when playback buffer recovers after a stall.
  var onUnstall: (() -> Void)? { get set }
}

/// Production AVPlayer wrapper that handles AVPlayerItem KVO internally.
@MainActor
public class AVPlayerWrapper: AVPlayerProviding {
  private var player: AVPlayer?
  private var statusObservation: NSKeyValueObservation?
  private var bufferEmptyObservation: NSKeyValueObservation?
  private var likelyToKeepUpObservation: NSKeyValueObservation?

  public var onStall: (() -> Void)?
  public var onUnstall: (() -> Void)?

  public var volume: Float {
    get { player?.volume ?? 0 }
    set { player?.volume = newValue }
  }

  public var currentTimeSeconds: Double {
    player?.currentTime().seconds ?? 0
  }

  public func play() {
    player?.play()
  }

  public func pause() {
    player?.pause()
  }

  public func seek(to time: CMTime) async -> Bool {
    guard let player else { return false }
    return await withCheckedContinuation { continuation in
      player.seek(to: time) { finished in
        continuation.resume(returning: finished)
      }
    }
  }

  public func loadURL(_ url: URL) async throws {
    let item = AVPlayerItem(url: url)
    let newPlayer = AVPlayer(playerItem: item)
    newPlayer.automaticallyWaitsToMinimizeStalling = false
    self.player = newPlayer

    setupBufferObservations(for: item)
    try await waitForReady(item: item)
  }

  private func setupBufferObservations(for item: AVPlayerItem) {
    bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) {
      [weak self] _, change in
      guard let self, change.newValue == true else { return }
      Task { @MainActor in self.onStall?() }
    }
    likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) {
      [weak self] _, change in
      guard let self, change.newValue == true else { return }
      Task { @MainActor in self.onUnstall?() }
    }
  }

  private func waitForReady(item: AVPlayerItem) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      self.statusObservation = item.observe(\.status, options: [.new]) {
        [weak self] observedItem, _ in
        guard let self else { return }

        Task { @MainActor in
          switch observedItem.status {
          case .readyToPlay:
            self.statusObservation?.invalidate()
            self.statusObservation = nil
            continuation.resume()
          case .failed:
            self.statusObservation?.invalidate()
            self.statusObservation = nil
            let error =
              observedItem.error
              ?? StationPlayerError.playbackError("AVPlayerItem failed to load")
            continuation.resume(throwing: error)
          case .unknown:
            // Not yet determined — keep observing.
            return
          @unknown default:
            self.statusObservation?.invalidate()
            self.statusObservation = nil
            continuation.resume(
              throwing: StationPlayerError.playbackError(
                "AVPlayerItem entered unexpected status"))
          }
        }
      }
    }
  }

  public func clearItem() {
    statusObservation?.invalidate()
    statusObservation = nil
    bufferEmptyObservation?.invalidate()
    bufferEmptyObservation = nil
    likelyToKeepUpObservation?.invalidate()
    likelyToKeepUpObservation = nil
    onStall = nil
    onUnstall = nil
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
  }

  public func preroll(atRate rate: Float) async -> Bool {
    guard let player else { return false }
    return await withCheckedContinuation { continuation in
      player.preroll(atRate: rate) { finished in
        continuation.resume(returning: finished)
      }
    }
  }

  public func cancelPendingPrerolls() {
    player?.cancelPendingPrerolls()
  }

  public func setRate(_ rate: Float, time: CMTime, atHostTime hostTime: CMTime) {
    player?.setRate(rate, time: time, atHostTime: hostTime)
  }

  public func addBoundaryTimeObserver(
    forTimes times: [NSValue],
    queue: DispatchQueue?,
    using block: @escaping @Sendable () -> Void
  ) -> Any? {
    guard let player else { return nil }
    return player.addBoundaryTimeObserver(forTimes: times, queue: queue, using: block)
  }

  public func removeBoundaryTimeObserver(_ token: Any) {
    player?.removeTimeObserver(token)
  }

  deinit {
    statusObservation?.invalidate()
    bufferEmptyObservation?.invalidate()
    likelyToKeepUpObservation?.invalidate()
  }
}
