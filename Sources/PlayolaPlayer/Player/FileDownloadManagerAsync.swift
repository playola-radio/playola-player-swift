//
//  FileDownloadManagerAsync.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 8/2/25.
//

import Foundation
import os.log

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

  /// Cache directory URL
  private var cacheDirectoryURL: URL {
    let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    return documentsPath.appendingPathComponent(Self.subfolderName)
  }

  public init() {
    createCacheDirectoryIfNeeded()
  }

  private func createCacheDirectoryIfNeeded() {
    do {
      try fileManager.createDirectory(
        at: cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    } catch {
      logger.error("Failed to create cache directory: \(error)")
    }
  }

  /// Downloads a file asynchronously
  /// - Parameters:
  ///   - url: The URL to download from
  ///   - downloadId: Unique identifier for this download
  ///   - forceRedownload: If true, bypasses cache and forces fresh download
  /// - Returns: The local file URL where the file was saved
  public func downloadFile(
    from url: URL,
    downloadId: String,
    forceRedownload: Bool = false
  ) async throws -> URL {
    // Check cache first
    if !forceRedownload, let cachedURL = getCachedFile(for: url) {
      logger.info("Using cached file for \(url.lastPathComponent)")
      return cachedURL
    }

    // Create destination URL
    let destinationURL = cacheURL(for: url)

    // Create new downloader
    let downloader = FileDownloaderAsync()
    downloaders[downloadId] = downloader

    defer {
      downloaders.removeValue(forKey: downloadId)
    }

    do {
      let result = try await downloader.download(from: url, to: destinationURL)

      // Update cache
      // File is already at the correct location after download

      return result.localURL
    } catch {
      await errorReporter.reportError(error)
      throw error
    }
  }

  /// Downloads a file with progress tracking
  /// - Parameters:
  ///   - url: The URL to download from
  ///   - downloadId: Unique identifier for this download
  ///   - forceRedownload: If true, bypasses cache and forces fresh download
  ///   - progressHandler: Called with download progress (0.0 to 1.0)
  /// - Returns: The local file URL where the file was saved
  public func downloadFileWithProgress(
    from url: URL,
    downloadId: String,
    forceRedownload: Bool = false,
    progressHandler: @escaping (Double) -> Void
  ) async throws -> URL {
    // Check cache first
    if !forceRedownload, let cachedURL = getCachedFile(for: url) {
      logger.info("Using cached file for \(url.lastPathComponent)")
      progressHandler(1.0)  // Indicate immediate completion
      return cachedURL
    }

    // Create destination URL
    let destinationURL = cacheURL(for: url)

    // Create new downloader
    let downloader = FileDownloaderAsync()
    downloaders[downloadId] = downloader

    defer {
      downloaders.removeValue(forKey: downloadId)
    }

    // Use the progress stream
    let eventStream = await downloader.downloadWithProgress(from: url, to: destinationURL)

    for await event in eventStream {
      switch event {
      case .progress(let progress):
        progressHandler(progress)

      case .completed(let result):
        // Update cache - file is already at the correct location
        return result.localURL

      case .failed(let error):
        await errorReporter.reportError(error)
        throw error
      }
    }

    // This should never be reached, but Swift requires it
    throw URLError(.unknown)
  }

  /// Cancels a specific download
  /// - Parameter downloadId: The ID of the download to cancel
  public func cancelDownload(_ downloadId: String) async {
    if let downloader = downloaders[downloadId] {
      await downloader.cancel()
      downloaders.removeValue(forKey: downloadId)
      logger.info("Cancelled download: \(downloadId)")
    }
  }

  /// Cancels all active downloads (async version for internal use)
  public func cancelAllDownloads() async {
    await cancelAllDownloadsInternal()
  }

  /// Returns the IDs of all active downloads
  public var activeDownloadIds: Set<String> {
    Set(downloaders.keys)
  }

  /// Preloads multiple files concurrently
  /// - Parameter urls: Array of URLs to preload
  /// - Returns: Dictionary mapping URLs to their local file paths (successful downloads only)
  public func preloadFiles(urls: [URL]) async -> [URL: URL] {
    var results: [URL: URL] = [:]

    await withTaskGroup(of: (URL, URL?).self) { group in
      for (index, url) in urls.enumerated() {
        group.addTask {
          do {
            let localURL = try await self.downloadFile(
              from: url,
              downloadId: "preload-\(index)-\(UUID().uuidString)"
            )
            return (url, localURL)
          } catch {
            self.logger.error("Failed to preload \(url): \(error)")
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

  /// Cleans up the cache by removing old files
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
        at: cacheDirectoryURL,
        includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
        options: [.skipsHiddenFiles]
      )

      var totalSize: Int64 = 0
      var fileInfos: [(url: URL, size: Int64, date: Date)] = []

      for fileURL in contents {
        let attributes = try fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        if let size = attributes.fileSize,
          let date = attributes.creationDate
        {
          totalSize += Int64(size)
          fileInfos.append((url: fileURL, size: Int64(size), date: date))
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
          logger.info("Pruned cache file: \(fileInfo.url.lastPathComponent)")
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

    logger.info("Cancelled all downloads")
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
  public func pruneCache(maxSize: Int64?, excludeFilepaths: [String]) throws {
    // For now, we'll use the internal prune method
    pruneCacheInternal(maxSize: maxSize ?? Self.MAX_AUDIO_FOLDER_SIZE)
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
