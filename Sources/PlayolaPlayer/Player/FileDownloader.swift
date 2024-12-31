//
//  FileDownloader.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/30/24.
//

import Foundation

public final class FileDownloader: NSObject, @unchecked Sendable {
    var totalDownloaded: Float = 0 {
        didSet {
            self.handleDownloadedProgressPercent?(totalDownloaded)
        }
    }
    typealias progressClosure = ((Float) -> Void)
    var handleDownloadedProgressPercent: progressClosure!

    // MARK: - Properties
    private var configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

        return session
    }()

    // MARK: - Initialization
    override init() {
        self.configuration = URLSessionConfiguration.background(withIdentifier: "backgroundTasks")

        super.init()
    }

    func download(url: URL, progress: ((Float) -> Void)?) {
        /// bind progress closure to View
        self.handleDownloadedProgressPercent = progress

        let task = session.downloadTask(with: url)
        task.resume()
    }

}

extension FileDownloader: URLSessionDownloadDelegate {
  public func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        self.totalDownloaded = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
    print("TotalDownloaded: \(totalDownloaded)")
    }

    public func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        print("downloaded")
    }
}
