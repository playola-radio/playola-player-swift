//
//  FileDownloadManager.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/2/25.
//

import SwiftUI
import os.log

/// Errors specific to file downloading and caching
public enum FileDownloadError: Error, LocalizedError {
    case directoryCreationFailed(String)
    case fileMoveFailed(String)
    case fileNotFound(String)
    case invalidRemoteURL(String)
    case downloadFailed(String)
    case cachePruneFailed(String)

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path):
            return "Failed to create directory at path: \(path)"
        case .fileMoveFailed(let message):
            return "Failed to move downloaded file: \(message)"
        case .fileNotFound(let path):
            return "File not found at path: \(path)"
        case .invalidRemoteURL(let url):
            return "Invalid remote URL: \(url)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .cachePruneFailed(let message):
            return "Cache pruning failed: \(message)"
        }
    }
}

@Observable
@MainActor
public final class FileDownloadManager {
  public static let MAX_AUDIO_FOLDER_SIZE: Int64 = 52_428_800
  public static let subfolderName = "AudioFiles"
  public static let shared = FileDownloadManager()

  private var downloaders: Set<FileDownloader> = Set()
  private let errorReporter = PlayolaErrorReporter.shared

  private static let logger = OSLog(subsystem: "fm.playola.playolaCore", category: "FileDownloadManager")

  public func completeFileExists(path: String) -> Bool {
    return FileManager.default.fileExists(atPath: path)
  }

  public init() {
    createFolderIfNotExist()
  }

  private var fileDirectoryURL: URL! {
    let paths = NSSearchPathForDirectoriesInDomains(
      FileManager.SearchPathDirectory.documentDirectory,
      FileManager.SearchPathDomainMask.userDomainMask,
      true)
    let documentsDirectoryURL:URL = URL(fileURLWithPath: paths[0])
    return documentsDirectoryURL.appendingPathComponent(
      FileDownloadManager.subfolderName)
  }

  private func localURLFromRemoteURL(_ remoteURL:URL) -> URL {
    let filename = remoteURL.lastPathComponent
    return fileDirectoryURL.appendingPathComponent(filename)
  }

  private func createFolderIfNotExist() {
    let fileManager = FileManager.default
    do {
        try fileManager.createDirectory(atPath: fileDirectoryURL.path, withIntermediateDirectories: false, attributes: nil)
    } catch let error as NSError {
        let playolaError = FileDownloadError.directoryCreationFailed(fileDirectoryURL.path)
        errorReporter.reportError(error, context: playolaError.errorDescription ?? "Unknown error", level: .warning)
    }
  }

  public func downloadFile(remoteUrl: URL,
                           onProgress: ((Float) -> Void)?,
                           onCompletion: ((URL) -> Void)?) {
    let localUrl = localURLFromRemoteURL(remoteUrl)
    guard !FileManager().fileExists(atPath: localUrl.path) else {
      onCompletion?(localUrl)
      return
    }

    let downloader = FileDownloader(remoteUrl: remoteUrl,
                                    localUrl: localUrl,
                                    onProgress: onProgress,
                                    onCompletion: { [weak self] downloader in
      guard let self = self else { return }
      onCompletion?(downloader.localUrl)
      self.downloaders.remove(downloader)
    })
    self.downloaders.insert(downloader)
  }
}

// File Cache Handling
extension FileDownloadManager {
  private func calculateFolderCacheSize() -> Int64 {
    var bool: ObjCBool = false
    var folderFileSizeInBytes: Int64 = 0

    guard FileManager().fileExists(atPath: fileDirectoryURL.path,
                                   isDirectory: &bool),
          bool.boolValue else {
      return 0
    }
    let fileManager = FileManager.default
    do {
        let files = try fileManager.contentsOfDirectory(
            at: fileDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [])

        for file in files {
            do {
                let fullContentPath = file.path
                let attributes = try FileManager.default.attributesOfItem(atPath: fullContentPath)
                folderFileSizeInBytes += attributes[FileAttributeKey.size] as? Int64 ?? 0
            } catch let error {
                errorReporter.reportError(error, context: "Failed to get file size for \(file.lastPathComponent)", level: .warning)
                continue
            }
        }
    } catch let error {
        errorReporter.reportError(error, context: "Failed to read contents of directory", level: .warning)
    }
    return folderFileSizeInBytes
  }

  public func pruneCache(excludeFilepaths: [String] = []) {
    guard let directory = fileDirectoryURL else {
        let error = FileDownloadError.directoryCreationFailed("No directory URL available")
        errorReporter.reportError(error, level: .warning)
        return
    }

    let fileUrls: [URL]
    do {
        fileUrls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)
    } catch let error {
        errorReporter.reportError(error, context: "Failed to get directory contents during cache pruning", level: .warning)
        return
    }

    let files = fileUrls.compactMap { url -> (String, Date)? in
        do {
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
            return (url.path, date)
        } catch {
            errorReporter.reportError(error, context: "Failed to get file attributes for \(url.lastPathComponent)", level: .warning)
            return nil
        }
    }
    .sorted(by: { $0.1 < $1.1 })
    .map { $0.0 }
    .filter { !excludeFilepaths.contains($0) }

    let amountToDelete: Int64 = FileDownloadManager.MAX_AUDIO_FOLDER_SIZE - calculateFolderCacheSize()
    guard amountToDelete > 0 else { return }

    var totalRemoved: Int64 = 0

    for filepath in files {
        do {
            let url = URL(fileURLWithPath: filepath)
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try FileManager.default.removeItem(atPath: filepath)
            totalRemoved += Int64(fileSize)
            if totalRemoved >= amountToDelete { return }
        } catch let error {
            errorReporter.reportError(error, context: "Error removing file during cache pruning: \(filepath)", level: .warning)
        }
    }
  }
}
