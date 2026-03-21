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
}

/// Production AVPlayer wrapper that handles AVPlayerItem KVO internally.
@MainActor
public class AVPlayerWrapper: AVPlayerProviding {
  private var player: AVPlayer?
  private var statusObservation: NSKeyValueObservation?

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
    newPlayer.automaticallyWaitsToMinimizeStalling = true
    self.player = newPlayer

    try await waitForReady(item: item)
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
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
  }

  deinit {
    statusObservation?.invalidate()
  }
}
