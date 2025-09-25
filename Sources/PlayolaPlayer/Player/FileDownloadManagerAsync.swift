//
//  FileDownloadManagerAsync.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 8/2/25.
//

import Foundation
import os.log

private struct FileInfo {
  let url: URL
  let size: Int64
  let date: Date
}

/// Errors specific to file downloading and caching
public enum FileDownloadError: Error, LocalizedError {
  case directoryCreationFailed(String)
  case fileMoveFailed(String)
  case fileNotFound(String)
  case invalidRemoteURL(String)
  case downloadFailed(String)
  case cachePruneFailed(String)
  case downloadCancelled
  case unknownError

  public var errorDescription: String? {
    switch self {
    case let .directoryCreationFailed(path):
      return "Failed to create directory at path: \(path)"
    case let .fileMoveFailed(message):
      return "Failed to move downloaded file: \(message)"
    case let .fileNotFound(path):
      return "File not found at path: \(path)"
    case let .invalidRemoteURL(url):
      return "Invalid remote URL: \(url)"
    case let .downloadFailed(message):
      return "Download failed: \(message)"
    case let .cachePruneFailed(message):
      return "Cache pruning failed: \(message)"
    case .downloadCancelled:
      return "Download was cancelled"
    case .unknownError:
      return "An unknown error occurred"
    }
  }
}

/// Protocol defining the interface for file download management
///
/// This protocol provides methods to download, manage, and cache audio files
/// with support for progress tracking, cancellation, and cache management.
public protocol FileDownloadManaging {
  /// Downloads a file from a remote URL with progress tracking
  ///
  /// - Parameters:
  ///   - remoteUrl: The URL of the file to download
  ///   - progressHandler: A closure that receives download progress updates (0.0 to 1.0)
  ///   - completion: A closure called when download completes with either the local URL or an error
  /// - Returns: A unique identifier that can be used to cancel this specific download
  @discardableResult
  func downloadFile(
    remoteUrl: URL,
    progressHandler: @escaping (Float) -> Void,
    completion: @escaping (Result<URL, FileDownloadError>) -> Void
  ) -> UUID

  /// Downloads a file asynchronously from a remote URL
  /// - Parameters:
  ///   - remoteUrl: The URL of the file to download
  ///   - progressHandler: A closure that receives download progress updates (0.0 to 1.0)
  /// - Returns: The local URL where the file was saved
  /// - Throws: FileDownloadError if the download fails
  func downloadFileAsync(
    remoteUrl: URL,
    progressHandler: ((Float) -> Void)?
  ) async throws -> URL

  /// Cancels a specific download using its identifier
  /// - Parameter downloadId: The identifier of the download to cancel
  /// - Returns: True if a download was found and cancelled, false otherwise
  @discardableResult
  func cancelDownload(id downloadId: UUID) -> Bool

  /// Cancels all downloads for a specific remote URL
  /// - Parameter remoteUrl: The remote URL of the downloads to cancel
  /// - Returns: The number of downloads cancelled
  @discardableResult
  func cancelDownload(for remoteUrl: URL) -> Int

  /// Cancels all active downloads
  func cancelAllDownloads()

  /// Checks if a file already exists in the cache
  /// - Parameter remoteUrl: The remote URL to check
  /// - Returns: True if the file exists in the cache
  func fileExists(for remoteUrl: URL) -> Bool

  /// Returns the local URL where a file would be stored
  /// - Parameter remoteUrl: The remote URL of the file
  /// - Returns: The local cache URL for this file
  func localURL(for remoteUrl: URL) -> URL

  /// Clears all cached files
  /// - Throws: FileDownloadError if the cache couldn't be cleared
  func clearCache() throws

  /// Prunes the cache to stay under the specified size limit
  /// - Parameters:
  ///   - maxSize: Maximum size in bytes for the cache (nil uses default)
  ///   - excludeFilepaths: Paths to exclude from pruning
  /// - Throws: FileDownloadError if pruning fails
  func pruneCache(maxSize: Int64?, excludeFilepaths: [String]) throws

  /// Returns the current size of the cache in bytes
  /// - Returns: The size in bytes
  func currentCacheSize() -> Int64

  /// Returns the available disk space on the volume containing the cache
  /// - Returns: Available space in bytes, or nil if it couldn't be determined
  func availableDiskSpace() -> Int64?
}

/// Manages multiple file downloads using async/await pattern
/// Eliminates deadlocks by removing synchronous queue operations and locks
@MainActor
public class FileDownloadManagerAsync: FileDownloadManaging {
  /// Maximum default size of the audio file cache in bytes (50MB)
  public static let MAX_AUDIO_FOLDER_SIZE: Int64 = 52_428_800

  /// Name of the cache subfolder
  public static let subfolderName = "AudioFiles"

  /// Shared singleton instance
  public static let shared = FileDownloadManagerAsync()

  private var downloaders: [String: FileDownloaderAsync] = [:]
  private var downloadIdToKey: [UUID: String] = [:]
  private let errorReporter = PlayolaErrorReporter.shared
  private let logger = Logger(subsystem: "fm.playola", category: "FileDownloadManagerAsync")

  /// File manager for cache operations
  private let fileManager = FileManager.default

  #if os(iOS)
    /// Cache directory URL
    private var cacheDirectoryURL: URL {
      let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
      return documentsPath.appendingPathComponent(Self.subfolderName)
    }
  #endif

  #if os(macOS)
    /// Cache directory URL
    private var cacheDirectoryURL: URL {
      let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
      let bundleID = Bundle.main.bundleIdentifier ?? "fm.playola.PlayolaPlayer"
      return appSupport.appendingPathComponent(bundleID).appendingPathComponent(Self.subfolderName)
    }
  #endif

  public init() {
    createCacheDirectoryIfNeeded()
  }

  private func createCacheDirectoryIfNeeded() {
    do {
      try fileManager.createDirectory(
        at: cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil
      )
    } catch {
      logger.error("Failed to create cache directory: \(error)")
    }
  }

  public func downloadFile(from url: URL, downloadId: String, forceRedownload: Bool = false)
    async throws -> URL
  {
    if !forceRedownload, let cachedURL = getCachedFile(for: url) {
      return cachedURL
    }

    let destinationURL = cacheURL(for: url)
    do {
      try fileManager.createDirectory(
        at: cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil
      )
    } catch {
      throw FileDownloadError.directoryCreationFailed(cacheDirectoryURL.path)
    }

    let downloader = FileDownloaderAsync()
    downloaders[downloadId] = downloader
    defer { downloaders.removeValue(forKey: downloadId) }

    do {
      let result = try await downloader.download(from: url, to: destinationURL)
      return result.localURL
    } catch {
      Task {
        await errorReporter.reportError(error)
      }
      throw error
    }
  }

  public func downloadFileWithProgress(
    from url: URL,
    downloadId: String,
    forceRedownload: Bool = false,
    progressHandler: @escaping (Double) -> Void
  ) async throws -> URL {
    if !forceRedownload, let cachedURL = getCachedFile(for: url) {
      progressHandler(1.0)
      return cachedURL
    }

    let destinationURL = cacheURL(for: url)
    do {
      try fileManager.createDirectory(
        at: cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil
      )
    } catch {
      throw FileDownloadError.directoryCreationFailed(cacheDirectoryURL.path)
    }

    let downloader = FileDownloaderAsync()
    downloaders[downloadId] = downloader
    defer { downloaders.removeValue(forKey: downloadId) }

    let eventStream = await downloader.downloadWithProgress(from: url, to: destinationURL)
    for await event in eventStream {
      switch event {
      case let .progress(progress):
        progressHandler(progress)
      case let .completed(result):
        return result.localURL
      case let .failed(error):
        Task {
          await errorReporter.reportError(error)
        }
        throw error
      }
    }
    throw URLError(.unknown)
  }

  public func cancelDownload(_ downloadId: String) async {
    if let downloader = downloaders[downloadId] {
      await downloader.cancel()
      downloaders.removeValue(forKey: downloadId)
    }
  }

  public func cancelAllDownloads() async {
    await cancelAllDownloadsInternal()
  }

  public var activeDownloadIds: Set<String> { Set(downloaders.keys) }

  public func preloadFiles(urls: [URL]) async -> [URL: URL] {
    var results: [URL: URL] = [:]

    await withTaskGroup(of: (URL, URL?).self) { group in
      for (index, url) in urls.enumerated() {
        group.addTask {
          do {
            let localURL = try await self.downloadFile(
              from: url, downloadId: "preload-\(index)-\(UUID().uuidString)"
            )
            return (url, localURL)
          } catch {
            return (url, nil)
          }
        }
      }

      for await (url, localURL) in group {
        if let localURL = localURL {
          results[url] = localURL
        }
      }
    }

    return results
  }

  public func pruneCache() async {
    await Task.detached(priority: .utility) {
      await self.pruneCacheInternal()
    }.value
  }

  // MARK: - Cache Management

  private func getCachedFile(for remoteURL: URL) -> URL? {
    let localURL = cacheURL(for: remoteURL)
    return fileManager.fileExists(atPath: localURL.path) ? localURL : nil
  }

  private func cacheURL(for remoteURL: URL) -> URL {
    let fileName = remoteURL.lastPathComponent
    return cacheDirectoryURL.appendingPathComponent(fileName)
  }

  private func pruneCacheInternal(maxSize: Int64 = FileDownloadManagerAsync.MAX_AUDIO_FOLDER_SIZE)
    async
  {
    do {
      let contents = try fileManager.contentsOfDirectory(
        at: cacheDirectoryURL, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
        options: [.skipsHiddenFiles]
      )

      var totalSize: Int64 = 0
      var fileInfos: [FileInfo] = []

      for fileURL in contents {
        let attributes = try fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        if let size = attributes.fileSize, let date = attributes.creationDate {
          totalSize += Int64(size)
          fileInfos.append(FileInfo(url: fileURL, size: Int64(size), date: date))
        }
      }

      if totalSize > maxSize {
        // Sort by date (oldest first)
        fileInfos.sort { $0.date < $1.date }

        for fileInfo in fileInfos {
          if totalSize <= maxSize {
            break
          }

          try fileManager.removeItem(at: fileInfo.url)
          totalSize -= fileInfo.size
        }
      }
    } catch {
      logger.error("Failed to prune cache: \(error)")
    }
  }

  // MARK: - FileDownloadManaging Protocol Implementation

  /// Downloads a file from a remote URL with progress tracking (callback-based for compatibility)
  @discardableResult
  public func downloadFile(
    remoteUrl: URL,
    progressHandler: @escaping (Float) -> Void,
    completion: @escaping (Result<URL, FileDownloadError>) -> Void
  ) -> UUID {
    let downloadId = UUID()
    let downloadKey = "legacy-\(downloadId.uuidString)"
    downloadIdToKey[downloadId] = downloadKey

    Task {
      do {
        let localURL = try await downloadFileWithProgress(
          from: remoteUrl,
          downloadId: downloadKey,
          forceRedownload: false,
          progressHandler: { progress in
            progressHandler(Float(progress))
          }
        )
        completion(.success(localURL))
      } catch {
        let downloadError = mapErrorToFileDownloadError(error)
        completion(.failure(downloadError))
      }
      downloadIdToKey.removeValue(forKey: downloadId)
    }

    return downloadId
  }

  /// Downloads a file asynchronously from a remote URL
  public func downloadFileAsync(
    remoteUrl: URL,
    progressHandler: ((Float) -> Void)?
  ) async throws -> URL {
    let downloadKey = "async-\(UUID().uuidString)"

    if let progressHandler = progressHandler {
      return try await downloadFileWithProgress(
        from: remoteUrl,
        downloadId: downloadKey,
        forceRedownload: false,
        progressHandler: { progress in
          progressHandler(Float(progress))
        }
      )
    } else {
      return try await downloadFile(
        from: remoteUrl,
        downloadId: downloadKey,
        forceRedownload: false
      )
    }
  }

  /// Cancels a specific download using its identifier
  @discardableResult
  public func cancelDownload(id downloadId: UUID) -> Bool {
    guard let downloadKey = downloadIdToKey[downloadId] else {
      return false
    }

    Task {
      await cancelDownload(downloadKey)
    }

    downloadIdToKey.removeValue(forKey: downloadId)
    return true
  }

  /// Cancels all downloads for a specific remote URL
  @discardableResult
  public func cancelDownload(for remoteUrl: URL) -> Int {
    var cancelledCount = 0
    let urlString = remoteUrl.absoluteString

    // Find all downloads for this URL
    let keysToCancel = downloaders.keys.filter { key in
      key.contains(urlString)
    }

    Task {
      for key in keysToCancel {
        await cancelDownload(key)
        cancelledCount += 1
      }
    }

    return cancelledCount
  }

  /// Cancels all active downloads (protocol requirement - non-async)
  public func cancelAllDownloads() {
    Task {
      await self.cancelAllDownloadsInternal()
    }
  }

  /// Internal async version that actually cancels all downloads
  private func cancelAllDownloadsInternal() async {
    let activeDownloaders = Array(downloaders.values)
    downloaders.removeAll()

    // Cancel all downloads concurrently
    await withTaskGroup(of: Void.self) { group in
      for downloader in activeDownloaders {
        group.addTask {
          await downloader.cancel()
        }
      }
    }
  }

  /// Checks if a file already exists in the cache
  public func fileExists(for remoteUrl: URL) -> Bool {
    return getCachedFile(for: remoteUrl) != nil
  }

  /// Returns the local URL where a file would be stored
  public func getLocalUrl(for remoteUrl: URL) -> URL? {
    return getCachedFile(for: remoteUrl)
  }

  /// Returns the local URL where a file would be stored (protocol requirement)
  public func localURL(for remoteUrl: URL) -> URL {
    return cacheURL(for: remoteUrl)
  }

  /// Preloads a list of files
  public func preloadFiles(
    remoteUrls: [URL],
    completion: @escaping (Result<Int, FileDownloadError>) -> Void
  ) {
    Task {
      let results = await preloadFiles(urls: remoteUrls)
      completion(.success(results.count))
    }
  }

  /// Returns the current number of active downloads
  public var activeDownloadsCount: Int {
    return downloaders.count
  }

  /// Clears all cached files
  public func clearCache() throws {
    do {
      let contents = try fileManager.contentsOfDirectory(
        at: cacheDirectoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )

      for fileURL in contents {
        try fileManager.removeItem(at: fileURL)
      }
    } catch {
      throw FileDownloadError.cachePruneFailed(error.localizedDescription)
    }
  }

  /// Prunes the cache to stay under the specified size limit
  public func pruneCache(maxSize: Int64?, excludeFilepaths _: [String]) throws {
    // For now, we'll use the internal prune method synchronously
    // Note: This could block but maintains protocol compatibility
    Task {
      await pruneCacheInternal(maxSize: maxSize ?? Self.MAX_AUDIO_FOLDER_SIZE)
    }
  }

  /// Returns the current size of the cache in bytes
  public func currentCacheSize() -> Int64 {
    do {
      let contents = try fileManager.contentsOfDirectory(
        at: cacheDirectoryURL,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      )

      var totalSize: Int64 = 0
      for fileURL in contents {
        let attributes = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = attributes.fileSize {
          totalSize += Int64(size)
        }
      }
      return totalSize
    } catch {
      logger.error("Failed to calculate cache size: \(error)")
      return 0
    }
  }

  /// Returns the available disk space on the volume containing the cache
  public func availableDiskSpace() -> Int64? {
    do {
      let attributes = try fileManager.attributesOfFileSystem(forPath: cacheDirectoryURL.path)
      return attributes[.systemFreeSize] as? Int64
    } catch {
      logger.error("Failed to get available disk space: \(error)")
      return nil
    }
  }

  // MARK: - Private Helpers

  private func mapErrorToFileDownloadError(_ error: Error) -> FileDownloadError {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .cancelled:
        return .downloadCancelled
      case .notConnectedToInternet, .networkConnectionLost:
        return .downloadFailed("No internet connection")
      case .timedOut:
        return .downloadFailed("Request timed out")
      default:
        return .downloadFailed(urlError.localizedDescription)
      }
    }
    return .downloadFailed(error.localizedDescription)
  }
}
