//
//  ProgressCapturingDownloadManager.swift
//  PlayolaPlayer
//
//  Fake for testing sample-buffer loading-progress forwarding: captures each call's
//  progressHandler by URL and lets a test fire progress ticks and resolve/reject the
//  download on demand, deterministically — no need to race a real download.
//

import Foundation

@testable import PlayolaPlayer

@MainActor
final class ProgressCapturingDownloadManager: FileDownloadManaging {
  private(set) var callOrder: [URL] = []
  private var progressHandlers: [URL: (Float) -> Void] = [:]
  private var arrivalWaiters: [URL: CheckedContinuation<Void, Never>] = [:]
  private var completions: [URL: CheckedContinuation<URL, Error>] = [:]

  func downloadFileAsync(remoteUrl: URL, progressHandler: ((Float) -> Void)?) async throws -> URL {
    callOrder.append(remoteUrl)
    if let progressHandler { progressHandlers[remoteUrl] = progressHandler }
    arrivalWaiters.removeValue(forKey: remoteUrl)?.resume()
    return try await withCheckedThrowingContinuation { continuation in
      completions[remoteUrl] = continuation
    }
  }

  /// Suspends until `downloadFileAsync(remoteUrl:)` has been called for this URL (so its
  /// progress handler, if any, is captured) — lets a test fire progress deterministically
  /// instead of racing the controller's unstructured download Task.
  func waitForCall(_ url: URL) async {
    if callOrder.contains(url) { return }
    await withCheckedContinuation { continuation in arrivalWaiters[url] = continuation }
  }

  func fireProgress(_ url: URL, _ value: Float) {
    progressHandlers[url]?(value)
  }

  func completeDownload(_ url: URL, with localURL: URL? = nil) {
    completions.removeValue(forKey: url)?.resume(returning: localURL ?? url)
  }

  func failDownload(_ url: URL, with error: Error = FileDownloadError.downloadFailed("test")) {
    completions.removeValue(forKey: url)?.resume(throwing: error)
  }

  // MARK: - Unused protocol requirements (stubbed, matching MockFileDownloadManager)

  nonisolated func downloadFile(
    remoteUrl: URL, progressHandler: @escaping (Float) -> Void,
    completion: @escaping (Result<URL, FileDownloadError>) -> Void
  ) -> UUID {
    completion(.success(remoteUrl))
    return UUID()
  }

  nonisolated func cancelDownload(id: UUID) -> Bool { true }
  nonisolated func cancelDownload(for remoteUrl: URL) -> Int { 0 }
  nonisolated func cancelAllDownloads() {}
  nonisolated func fileExists(for remoteUrl: URL) -> Bool { false }
  nonisolated func localURL(for remoteUrl: URL) -> URL { remoteUrl }
  nonisolated func clearCache() throws {}
  func pruneCache(maxSize: Int64?, excludeFilepaths: [String]) async throws {}
  nonisolated func currentCacheSize() -> Int64 { 0 }
  nonisolated func availableDiskSpace() -> Int64? { 1_000_000 }
}
