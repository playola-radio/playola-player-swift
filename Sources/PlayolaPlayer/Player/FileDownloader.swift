//
//  FileDownloader.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/30/24.
//
import Foundation

@Observable
public final class FileDownloader: NSObject {
  /// Unique identifier for this download
  let id: UUID

  /// Remote URL being downloaded
  let remoteUrl: URL

  /// Local destination URL
  let localUrl: URL

  /// Current progress (0.0 to 1.0)
  private(set) var progress: Float = 0

  /// Flag indicating if this download has been cancelled
  private(set) var isCancelled = false

  /// Thread-safe property access
  private let lock = NSLock()

  /// The URLSession used for this download
  private var session: URLSession!

  /// The download task
  private var downloadTask: URLSessionDownloadTask?

  /// Error reporter for logging issues
  private let errorReporter = PlayolaErrorReporter.shared

  /// Completion handlers stored as atomic properties
  private var _progressHandler: ((Float) -> Void)?
  private var _completionHandler: ((FileDownloader) -> Void)?
  private var _errorHandler: ((Error) -> Void)?

  // Safe accessors with locking
  private func setProgressHandler(_ handler: ((Float) -> Void)?) {
    lock.lock()
    defer { lock.unlock() }
    _progressHandler = handler
  }

  private func setCompletionHandler(_ handler: ((FileDownloader) -> Void)?) {
    lock.lock()
    defer { lock.unlock() }
    _completionHandler = handler
  }

  private func setErrorHandler(_ handler: ((Error) -> Void)?) {
    lock.lock()
    defer { lock.unlock() }
    _errorHandler = handler
  }

  private func getProgressHandler() -> ((Float) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return _progressHandler
  }

  private func getCompletionHandler() -> ((FileDownloader) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return _completionHandler
  }

  private func getErrorHandler() -> ((Error) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return _errorHandler
  }

  public init(
    id: UUID,
    remoteUrl: URL,
    localUrl: URL,
    onProgress: ((Float) -> Void)?,
    onCompletion: ((FileDownloader) -> Void)?,
    onError: ((Error) -> Void)?
  ) {
    self.id = id
    self.remoteUrl = remoteUrl
    self.localUrl = localUrl

    super.init()

    setProgressHandler(onProgress)

    // Use weak self in completion blocks to avoid retain cycles
    setCompletionHandler({ [weak self] downloader in
      guard let self = self else { return }
      onCompletion?(downloader)
    })

    setErrorHandler({ [weak self] error in
      guard let self = self else { return }
      onError?(error)
    })

    let queue = OperationQueue()
    queue.name = "FileDownloader.delegateQueue"
    queue.maxConcurrentOperationCount = 1

    self.session = URLSession(
      configuration: .default,
      delegate: self,
      delegateQueue: queue
    )

    self.startDownload()
  }

  /// Starts the download task
  private func startDownload() {
    downloadTask = session.downloadTask(with: remoteUrl)
    downloadTask?.resume()
  }

  /// Cancels the download
  public func cancel() {
    lock.lock()
    isCancelled = true
    lock.unlock()

    downloadTask?.cancel()
    session.invalidateAndCancel()

    // Clean up partial downloads
    if FileManager.default.fileExists(atPath: localUrl.path) {
      try? FileManager.default.removeItem(at: localUrl)
    }

    // Release closure references
    setProgressHandler(nil)
    setCompletionHandler(nil)
    setErrorHandler(nil)
  }
}

extension FileDownloader: URLSessionDownloadDelegate {
  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    // Guard against division by zero
    let totalDownloaded =
      totalBytesExpectedToWrite > 0
      ? Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
      : 0

    lock.lock()
    self.progress = totalDownloaded
    lock.unlock()

    getProgressHandler()?(totalDownloaded)
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    lock.lock()
    let downloadIsCancelled = isCancelled
    lock.unlock()

    if downloadIsCancelled {
      return
    }

    let manager = FileManager()

    // Check if file already exists (could have been downloaded by another task)
    if manager.fileExists(atPath: localUrl.path) {
      getProgressHandler()?(1.0)
      getCompletionHandler()?(self)
      return
    }

    do {
      // Create parent directories if needed
      try manager.createDirectory(
        at: localUrl.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      // Move temporary file to final location
      try manager.moveItem(at: location, to: localUrl)

      getProgressHandler()?(1.0)
      getCompletionHandler()?(self)
    } catch let error {
      Task { @MainActor in
        let context =
          "Error moving downloaded file from temporary location to: \(self.localUrl.lastPathComponent)"
        self.errorReporter.reportError(error, context: context, level: .error)
        self.getErrorHandler()?(FileDownloadError.fileMoveFailed(error.localizedDescription))
      }
    }
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    lock.lock()
    let downloadIsCancelled = isCancelled
    lock.unlock()

    // First check if the download was cancelled intentionally
    if downloadIsCancelled {
      getErrorHandler()?(FileDownloadError.downloadCancelled)
      return
    }

    // Handle direct errors from the URLSession system
    if let error = error {
      // Don't report standard cancellations as errors
      if (error as NSError).code == NSURLErrorCancelled {
        getErrorHandler()?(FileDownloadError.downloadCancelled)
        return
      }

      // Handle network connectivity issues with specific error messages
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain {
        let errorType: String
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
          errorType = "No internet connection"
        case NSURLErrorTimedOut:
          errorType = "Request timed out"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
          errorType = "Cannot connect to host"
        case NSURLErrorNetworkConnectionLost:
          errorType = "Network connection lost"
        default:
          errorType = "Network error (\(nsError.code))"
        }

        Task { @MainActor in
          let context = "\(errorType) while downloading: \(remoteUrl.lastPathComponent)"
          self.errorReporter.reportError(error, context: context, level: .error)
        }

        getErrorHandler()?(FileDownloadError.downloadFailed(errorType))
        return
      }

      // Handle other direct errors
      Task { @MainActor in
        let context = "Download failed for URL: \(remoteUrl.lastPathComponent)"
        self.errorReporter.reportError(error, context: context, level: .error)
      }

      getErrorHandler()?(FileDownloadError.downloadFailed(error.localizedDescription))
      return
    }

    // If we reach here with no error, check HTTP status code
    // HTTP errors don't trigger the didFinishDownloadingTo method, but they
    // come here with a nil error and the status code in the response
    if let httpResponse = task.response as? HTTPURLResponse {
      let statusCode = httpResponse.statusCode

      if !(200...299).contains(statusCode) {
        // Create appropriate error based on HTTP status code
        let errorMessage: String
        let errorLevel: PlayolaErrorReportingLevel

        switch statusCode {
        case 401:
          errorMessage = "Unauthorized access (401)"
          errorLevel = .error
        case 403:
          errorMessage = "Access forbidden (403)"
          errorLevel = .error
        case 404:
          errorMessage = "Resource not found (404)"
          errorLevel = .error
        case 429:
          errorMessage = "Too many requests (429)"
          errorLevel = .warning
        case 500...599:
          errorMessage = "Server error (\(statusCode))"
          errorLevel = .error
        default:
          errorMessage = "HTTP error: \(statusCode)"
          errorLevel = .error
        }

        // Log the error with detailed context
        Task { @MainActor in
          let context = "\(errorMessage) for URL: \(remoteUrl.lastPathComponent)"

          // Create a custom error with HTTP information
          let httpError = NSError(
            domain: "fm.playola.PlayolaPlayer.HTTP",
            code: statusCode,
            userInfo: [
              NSLocalizedDescriptionKey: errorMessage,
              "url": remoteUrl.absoluteString,
              "statusCode": statusCode,
            ]
          )

          self.errorReporter.reportError(httpError, context: context, level: errorLevel)
        }

        // Notify via error handler
        getErrorHandler()?(FileDownloadError.downloadFailed(errorMessage))
        return
      }
    }

    // Edge case - we reach here if there's no HTTP error but didFinishDownloadingTo wasn't called
    // This is unusual and might indicate an empty response or other issue
    if !FileManager.default.fileExists(atPath: localUrl.path) {
      Task { @MainActor in
        let context =
          "Download completed with no error but file not found: \(remoteUrl.lastPathComponent)"
        let missingFileError = NSError(
          domain: "fm.playola.PlayolaPlayer",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "File not found after download"]
        )
        self.errorReporter.reportError(missingFileError, context: context, level: .warning)
      }

      getErrorHandler()?(FileDownloadError.fileNotFound("File not found after successful download"))
    }
  }
}
