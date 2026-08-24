//  SampleBufferLoadingProgressTests.swift
//  PlayolaPlayer
//
//  The sample-buffer backend must show download progress for the currently-airing spin,
//  matching the legacy path's `loadSpinWithProgress` — see CHANGELOG 0.21.0-beta.3. Only the
//  FIRST (currently-airing) spin's download drives `onLoadProgress`; upcoming spins' downloads
//  must not, and progress arriving after playback has started must be dropped (a late decode
//  or a stale download must never regress `.playing` back to `.loading`).

import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct SampleBufferLoadingProgressTests {
  private func makeController(_ downloadManager: ProgressCapturingDownloadManager)
    -> SampleBufferPlaybackController
  {
    SampleBufferPlaybackController(anchorDate: Date(), fileDownloadManager: downloadManager)
  }

  @Test("progress from the currently-airing spin's download reaches onLoadProgress")
  func firstSpinProgressReachesCallback() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])

    await downloadManager.waitForCall(url)
    downloadManager.fireProgress(url, 0.5)

    #expect(progressUpdates == [0.5])

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("an upcoming spin's download does not drive onLoadProgress")
  func upcomingSpinProgressIsIgnored() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)

    let firstUrl = URL(string: "https://example.com/first.m4a")!
    let firstSpin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: firstUrl))
    controller.start(with: [firstSpin])
    await downloadManager.waitForCall(firstUrl)

    let upcomingUrl = URL(string: "https://example.com/upcoming.m4a")!
    let upcomingSpin = Spin.mockWith(
      id: "spin-upcoming",
      airtime: Date().addingTimeInterval(300),
      audioBlock: .mockWith(downloadUrl: upcomingUrl))
    controller.addUpcoming([upcomingSpin])
    await downloadManager.waitForCall(upcomingUrl)

    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }
    downloadManager.fireProgress(upcomingUrl, 0.3)

    #expect(progressUpdates.isEmpty)

    downloadManager.completeDownload(firstUrl)
    downloadManager.completeDownload(upcomingUrl)
    controller.stop()
  }

  @Test("progress arriving after playback started is dropped")
  func progressAfterPlaybackStartedIsDropped() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()

    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }
    downloadManager.fireProgress(url, 0.9)

    #expect(progressUpdates.isEmpty)

    downloadManager.completeDownload(url)
    controller.stop()
  }
}
