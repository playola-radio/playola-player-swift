//
//  FileDownloaderAsync.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 8/2/25.
//

import Foundation
import os.log

/// An async/await-based file downloader that eliminates deadlock issues
/// by using Swift Concurrency instead of locks and synchronous operations
public actor FileDownloaderAsync {
  private var downloadTask: URLSessionDownloadTask?
  private var progressContinuation: AsyncStream<Double>.Continuation?
  private var isCancelled = false

  private let logger = Logger(subsystem: "fm.playola", category: "FileDownloaderAsync")

  /// Result of a successful download
  public struct DownloadResult {
    public let localURL: URL
    public let response: URLResponse
  }

  /// Download progress events
  public enum DownloadEvent {
    case progress(Double)
    case completed(DownloadResult)
    case failed(Error)
  }

  /// Downloads a file from the given URL to the destination
  /// - Parameters:
  ///   - url: The URL to download from
  ///   - destinationURL: The local file URL to save to
  /// - Returns: The download result
  public func download(from url: URL, to destinationURL: URL) async throws -> DownloadResult {
    guard !isCancelled else {
      throw URLError(.cancelled)
    }

    // Create a custom URLSession to avoid sharing state
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 300
    configuration.waitsForConnectivity = true

    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let (tempURL, response) = try await session.download(from: url)

    guard !isCancelled else {
      try? FileManager.default.removeItem(at: tempURL)
      throw URLError(.cancelled)
    }

    // Move the file immediately while we still have access to tempURL
    try await moveFile(from: tempURL, to: destinationURL)

    return DownloadResult(localURL: destinationURL, response: response)
  }

  /// Downloads a file with progress updates via AsyncStream
  /// - Parameters:
  ///   - url: The URL to download from
  ///   - destinationURL: The local file URL to save to
  /// - Returns: An AsyncStream of download events
  public func downloadWithProgress(
    from url: URL,
    to destinationURL: URL
  ) -> AsyncStream<DownloadEvent> {
    AsyncStream { continuation in
      Task {
        await self.performDownload(
          from: url,
          to: destinationURL,
          continuation: continuation
        )
      }
    }
  }

  private func performDownload(
    from url: URL,
    to destinationURL: URL,
    continuation: AsyncStream<DownloadEvent>.Continuation
  ) async {
    guard !isCancelled else {
      continuation.yield(.failed(URLError(.cancelled)))
      continuation.finish()
      return
    }

    do {
      // Create a dedicated session with delegate
      let delegate = DownloadDelegate(
        progressHandler: { progress in
          continuation.yield(.progress(progress))
        },
        destinationURL: destinationURL,
        logger: logger
      )

      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 300
      configuration.waitsForConnectivity = true

      let session = URLSession(
        configuration: configuration,
        delegate: delegate,
        delegateQueue: nil
      )

      defer { session.invalidateAndCancel() }

      let task = session.downloadTask(with: url)
      self.downloadTask = task

      // Use async continuation to wait for download completion
      let (finalURL, response) = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
        delegate.completionHandler = { result in
          switch result {
          case .success(let (url, response)):
            continuation.resume(returning: (url, response))
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
        task.resume()
      }

      guard !isCancelled else {
        // File is already moved to final location, clean it up
        try? FileManager.default.removeItem(at: finalURL)
        throw URLError(.cancelled)
      }

      let result = DownloadResult(localURL: finalURL, response: response)
      continuation.yield(.completed(result))

    } catch {
      continuation.yield(.failed(error))
    }

    continuation.finish()
  }

  private func moveFile(from source: URL, to destination: URL) async throws {
    // Perform file operations on a background queue to avoid blocking
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      Task.detached(priority: .utility) {
        do {
          let fileManager = FileManager.default

          // Check if source file exists
          if !fileManager.fileExists(atPath: source.path) {
            throw URLError(.fileDoesNotExist)
          }

          if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
          }

          let destinationDirectory = destination.deletingLastPathComponent()

          if !fileManager.fileExists(atPath: destinationDirectory.path) {
            try fileManager.createDirectory(
              at: destinationDirectory,
              withIntermediateDirectories: true,
              attributes: nil
            )
          }

          try fileManager.moveItem(at: source, to: destination)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Cancels the current download
  public func cancel() {
    isCancelled = true
    downloadTask?.cancel()
  }

  /// URLSession delegate for handling download progress and completion
  private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void
    var completionHandler: ((Result<(URL, URLResponse), Error>) -> Void)?
    private var hasCompleted = false
    let destinationURL: URL
    let logger: Logger

    init(progressHandler: @escaping (Double) -> Void, destinationURL: URL, logger: Logger) {
      self.progressHandler = progressHandler
      self.destinationURL = destinationURL
      self.logger = logger
    }

    func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didWriteData bytesWritten: Int64,
      totalBytesWritten: Int64,
      totalBytesExpectedToWrite: Int64
    ) {
      guard totalBytesExpectedToWrite > 0 else { return }
      let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
      progressHandler(progress)
    }

    func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didFinishDownloadingTo location: URL
    ) {
      guard !hasCompleted else { return }
      hasCompleted = true

      // Move the file IMMEDIATELY in the delegate callback to avoid race condition
      do {
        let fileManager = FileManager.default

        // Remove existing file if it exists
        if fileManager.fileExists(atPath: self.destinationURL.path) {
          try fileManager.removeItem(at: self.destinationURL)
        }

        // Ensure destination directory exists
        let destinationDirectory = self.destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destinationDirectory.path) {
          try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: nil
          )
        }

        // Move the file immediately
        try fileManager.moveItem(at: location, to: self.destinationURL)

        if let response = downloadTask.response {
          // Now return the final destination URL
          completionHandler?(.success((self.destinationURL, response)))
        } else {
          completionHandler?(.failure(URLError(.badServerResponse)))
        }
      } catch {
        completionHandler?(.failure(error))
      }
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      didCompleteWithError error: Error?
    ) {
      guard !hasCompleted else { return }

      if let error = error {
        hasCompleted = true
        completionHandler?(.failure(error))
      }
      // Don't call completion handler for successful completion here
      // because didFinishDownloadingTo already handled it
    }
  }
}
