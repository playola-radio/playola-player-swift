//
//  FileDownloader.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/30/24.
//
public class FileDownloader: URLSessionDelegate {
  var fileURL: URL
  var downloadTask: URLSessionDownloadTask

  init(fileUrl: URL) {
    
  }

  var progress: Float = 0 {
    didSet {
      print("newValue: \(progress)")
    }
  }
  func urlSession(_ session: URLSession,
                  downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
       if downloadTask == self.downloadTask {
         self.progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
  }
}
