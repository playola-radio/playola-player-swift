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

    public func download(from url: URL, to destinationURL: URL) async throws -> DownloadResult {
        guard !isCancelled else { throw URLError(.cancelled) }

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

        try await moveFile(from: tempURL, to: destinationURL)
        return DownloadResult(localURL: destinationURL, response: response)
    }

    public func downloadWithProgress(from url: URL, to destinationURL: URL) -> AsyncStream<
        DownloadEvent
    > {
        AsyncStream { continuation in
            let task = Task {
                await self.performDownload(from: url, to: destinationURL, continuation: continuation)
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func performDownload(
        from url: URL,
        to destinationURL: URL,
        continuation: AsyncStream<DownloadEvent>.Continuation
    ) async {
        guard !isCancelled, !Task.isCancelled else {
            continuation.yield(.failed(URLError(.cancelled)))
            continuation.finish()
            return
        }

        do {
            let delegate = DownloadDelegate(
                progressHandler: { continuation.yield(.progress($0)) },
                destinationURL: destinationURL,
                logger: logger
            )

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = true

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            let task = session.downloadTask(with: url)
            downloadTask = task

            let (finalURL, response) = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                delegate.completionHandler = { result in
                    switch result {
                    case .success(let (url, response)): continuation.resume(returning: (url, response))
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
                task.resume()
            }

            guard !isCancelled, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: finalURL)
                throw URLError(.cancelled)
            }

            continuation.yield(.completed(DownloadResult(localURL: finalURL, response: response)))
        } catch {
            continuation.yield(.failed(error))
        }
        continuation.finish()
    }

    private func moveFile(from source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .utility) {
                do {
                    let fileManager = FileManager.default
                    guard fileManager.fileExists(atPath: source.path) else {
                        throw URLError(.fileDoesNotExist)
                    }

                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }

                    let destinationDirectory = destination.deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: destinationDirectory.path) {
                        try fileManager.createDirectory(
                            at: destinationDirectory, withIntermediateDirectories: true, attributes: nil
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
            _: URLSession,
            downloadTask _: URLSessionDownloadTask,
            didWriteData _: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressHandler(progress)
        }

        func urlSession(
            _: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard !hasCompleted else { return }
            hasCompleted = true

            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                let destinationDirectory = destinationURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: destinationDirectory.path) {
                    try fileManager.createDirectory(
                        at: destinationDirectory, withIntermediateDirectories: true, attributes: nil
                    )
                }

                try fileManager.moveItem(at: location, to: destinationURL)

                if let response = downloadTask.response {
                    completionHandler?(.success((destinationURL, response)))
                } else {
                    completionHandler?(.failure(URLError(.badServerResponse)))
                }
            } catch {
                completionHandler?(.failure(error))
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            guard !hasCompleted else { return }

            if let error = error {
                hasCompleted = true
                completionHandler?(.failure(error))
            }
        }
    }
}
