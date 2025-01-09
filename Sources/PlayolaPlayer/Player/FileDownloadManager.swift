//
//  FileDownloadManager.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/2/25.
//

import SwiftUI

@Observable
public final class FileDownloadManager: Sendable {
  public static let subfolderName = "AudioFiles"
  public static let shared = FileDownloadManager()

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
      FileDownloader.subfolderName)
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
        print(error.localizedDescription);
    }
  }

  public func downloadFile(remoteUrl: URL,
                            onProgress: ((Float) -> Void)?,
                            onCompletion: ((URL) -> Void)?) {
    let localUrl = localURLFromRemoteURL(remoteUrl)

    guard !completeFileExists(path: localUrl.path) else {
      print("detected file exists at path: \(localUrl.path)")
      onProgress?(1.0)
      onCompletion?(localUrl)
      return
    }
    print("file not detected at path: \(localUrl.path)")

    let downloader = FileDownloader(remoteUrl: remoteUrl,
                                    localUrl: localUrl,
                                    onProgress: onProgress,
                                    onCompletion: onCompletion)
  }
}
