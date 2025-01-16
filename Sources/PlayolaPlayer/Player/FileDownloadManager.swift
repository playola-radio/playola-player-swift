//
//  FileDownloadManager.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/2/25.
//

import SwiftUI

public final class FileDownloadManager {
  public static let MAX_AUDIO_FOLDER_SIZE: Int64 = 52_428_800
  public static let subfolderName = "AudioFiles"

  private var downloaders: Set<FileDownloader> = Set()

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
        print(error.localizedDescription);
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
                                    onCompletion: { downloader in
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
    let files = try! fileManager.contentsOfDirectory(
      at: fileDirectoryURL,
      includingPropertiesForKeys: nil,
      options: [])

    for file in files {
      do {
        let fullContentPath = file.path
        let attributes = try FileManager.default.attributesOfItem(atPath: fullContentPath)
        folderFileSizeInBytes += attributes[FileAttributeKey.size] as? Int64 ?? 0
      } catch _ {
        continue
      }
    }
    return folderFileSizeInBytes
  }

  public func pruneCache(excludeFilepaths: [String] = []) {
    guard let directory = fileDirectoryURL else { return }  // TODO: proper error handling
    guard let fileUrls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options:.skipsHiddenFiles) else {
      return
    }
    let files = fileUrls.map { url in
      (url.path, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast)
    }
      .sorted(by: { $0.1 < $1.1 })
      .map { $0.0 }
      .filter { !excludeFilepaths.contains($0) }
    
    let amountToDelete:Int64 = FileDownloadManager.MAX_AUDIO_FOLDER_SIZE - calculateFolderCacheSize()
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
        print("error removing file \(filepath)")
      }
    }
  }
}
