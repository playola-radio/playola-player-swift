//
//  MockFileDownloadManager.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 7/11/25.
//

import Foundation

@testable import PlayolaPlayer

@MainActor
class MockFileDownloadManager: FileDownloadManaging {

  nonisolated func downloadFile(
    remoteUrl: URL, progressHandler: @escaping (Float) -> Void,
    completion: @escaping (Result<URL, FileDownloadError>) -> Void
  ) -> UUID {
    let url = URL(string: "file:///mock/path")!
    completion(.success(url))
    return UUID()
  }

  func downloadFileAsync(remoteUrl: URL, progressHandler: ((Float) -> Void)?) async throws -> URL {
    return URL(string: "file:///mock/path")!
  }

  nonisolated func cancelDownload(id: UUID) -> Bool {
    return true
  }

  nonisolated func cancelDownload(for remoteUrl: URL) -> Int {
    return 0
  }

  nonisolated func cancelAllDownloads() {
  }

  nonisolated func fileExists(for remoteUrl: URL) -> Bool {
    return false
  }

  nonisolated func localURL(for remoteUrl: URL) -> URL {
    return URL(string: "file:///mock/local/\(remoteUrl.lastPathComponent)")!
  }

  nonisolated func clearCache() throws {
  }

  nonisolated func pruneCache(maxSize: Int64?, excludeFilepaths: [String]) throws {
  }

  nonisolated func currentCacheSize() -> Int64 {
    return 0
  }

  nonisolated func availableDiskSpace() -> Int64? {
    return 1_000_000
  }
}
