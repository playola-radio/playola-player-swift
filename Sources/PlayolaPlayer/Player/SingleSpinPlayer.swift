import AVFoundation
import Foundation
import os.log

@MainActor
public final class SingleSpinPlayer {
  private static let logger = OSLog(subsystem: "fm.playola.playolaCore", category: "SingleSpin")

  // Deps (mirroring SpinPlayer)
  private let playolaMainMixer: PlayolaMainMixer = .shared
  private let engine: AVAudioEngine = PlayolaMainMixer.shared.engine
  private let playerNode = AVAudioPlayerNode()
  private let fileDownloadManager: FileDownloadManaging
  private let errorReporter = PlayolaErrorReporter.shared

  public private(set) var spin: Spin
  private var fileURL: URL?
  private var activeDownloadId: UUID?

  public init(spin: Spin, fileDownloadManager: FileDownloadManaging? = nil) {
    self.spin = spin
    self.fileDownloadManager = fileDownloadManager ?? FileDownloadManagerAsync.shared

    // Configure audio session exactly like SpinPlayer
    playolaMainMixer.configureAudioSession()

    // Connect like SpinPlayer does (into the shared main mixer)
    engine.attach(playerNode)
    engine.connect(
      playerNode,
      to: playolaMainMixer.mixerNode,
      format: TapProperties.default.format
    )

    // Prepare engine once
    engine.prepare()

    // Kick off download
    Task { @MainActor in
      await startDownloadAndSchedule()
    }
  }

  public func stop() {
    os_log("🛑 SingleSpinPlayer.stop()", log: SingleSpinPlayer.logger, type: .info)

    if let id = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: id)
      activeDownloadId = nil
    }

    if engine.isRunning {
      playerNode.stop()
      playerNode.reset()
    }

    // keep engine/mixer graph alive for reuse; no teardown needed
  }

  // MARK: - Internals

  private func startDownloadAndSchedule() async {
    guard let remote = spin.audioBlock.downloadUrl else {
      await errorReporter.reportError(
        NSError(
          domain: "SingleSpinPlayer", code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Spin has no download URL"]),
        context: "Missing download URL", level: .error)
      return
    }

    os_log(
      "⬇️ Downloading: %{public}@", log: SingleSpinPlayer.logger, type: .info, remote.absoluteString)

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      self.activeDownloadId = self.fileDownloadManager.downloadFile(
        remoteUrl: remote,
        progressHandler: { _ in },
        completion: { [weak self] result in
          guard let self else {
            cont.resume()
            return
          }
          switch result {
          case .success(let url):
            self.fileURL = url
            os_log(
              "✅ Downloaded file: %{public}@", log: SingleSpinPlayer.logger, type: .info,
              url.lastPathComponent)
            Task { @MainActor in
              self.scheduleStartInTwoSeconds()
              cont.resume()
            }
          case .failure(let err):
            Task { @MainActor in
              await self.errorReporter.reportError(
                err, context: "SingleSpin download failed", level: .error)
            }
            cont.resume()
          }
        }
      )
    }
  }

  private func scheduleStartInTwoSeconds() {
    guard let url = fileURL else { return }

    do {
      // Ensure engine is running
      if !engine.isRunning {
        playolaMainMixer.configureAudioSession()
        try engine.start()
      }

      let file = try AVAudioFile(forReading: url)

      // Scheme A: schedule at nil, then play(at:)
      playerNode.stop()
      playerNode.scheduleFile(file, at: nil)

      // Host-time 2s from *now*
      let hostNow = engine.outputNode.lastRenderTime?.hostTime ?? mach_absolute_time()
      let delta = AVAudioTime.hostTime(forSeconds: 2.0)
      let when = AVAudioTime(hostTime: hostNow + delta)

      os_log(
        "⏱️ Scheduling spin to start in 2.0s (host=%llu)", log: SingleSpinPlayer.logger, type: .info,
        when.hostTime)

      playerNode.play(at: when)
    } catch {
      Task { @MainActor in
        await errorReporter.reportError(
          error, context: "Failed to schedule SingleSpin start", level: .error)
      }
    }
  }
}
