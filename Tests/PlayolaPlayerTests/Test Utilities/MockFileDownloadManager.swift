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
        remoteUrl _: URL, progressHandler _: @escaping (Float) -> Void,
        completion: @escaping (Result<URL, FileDownloadError>) -> Void
    ) -> UUID {
        let url = URL(string: "file:///mock/path")!
        completion(.success(url))
        return UUID()
    }

    func downloadFileAsync(remoteUrl _: URL, progressHandler _: ((Float) -> Void)?) async throws -> URL {
        return URL(string: "file:///mock/path")!
    }

    nonisolated func cancelDownload(id _: UUID) -> Bool {
        return true
    }

    nonisolated func cancelDownload(for _: URL) -> Int {
        return 0
    }

    nonisolated func cancelAllDownloads() {}

    nonisolated func fileExists(for _: URL) -> Bool {
        return false
    }

    nonisolated func localURL(for remoteUrl: URL) -> URL {
        return URL(string: "file:///mock/local/\(remoteUrl.lastPathComponent)")!
    }

    nonisolated func clearCache() throws {}

    nonisolated func pruneCache(maxSize _: Int64?, excludeFilepaths _: [String]) throws {}

    nonisolated func currentCacheSize() -> Int64 {
        return 0
    }

    nonisolated func availableDiskSpace() -> Int64? {
        return 1_000_000
    }
}
