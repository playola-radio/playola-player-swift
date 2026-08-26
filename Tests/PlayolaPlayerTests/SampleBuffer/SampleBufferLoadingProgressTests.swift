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

  @Test("a malformed first spin (nil downloadUrl) does not leak progress onto a later spin")
  func nilUrlFirstSpinDoesNotLeakProgressToLaterSpin() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }

    // The true first (currently-airing) spin is malformed: its audioBlock has no downloadUrl, so it
    // can never download. A later spin with a real URL must NOT inherit "first-spin" progress reporting
    // (progress must track the identity of the true first spin, not the first successfully-ingested one).
    // mockWith(downloadUrl:) can't force a genuinely-nil URL (nil == omitted), so build it by hand.
    let base = AudioBlock.mock
    let nilUrlBlock = AudioBlock(
      id: base.id, title: base.title, artist: base.artist, durationMS: base.durationMS,
      endOfMessageMS: base.endOfMessageMS, beginningOfOutroMS: base.beginningOfOutroMS,
      endOfIntroMS: base.endOfIntroMS, lengthOfOutroMS: base.lengthOfOutroMS, downloadUrl: nil,
      s3Key: base.s3Key, s3BucketName: base.s3BucketName, type: base.type,
      createdAt: base.createdAt, updatedAt: base.updatedAt, album: base.album,
      popularity: base.popularity, youTubeId: base.youTubeId, isrc: base.isrc,
      spotifyId: base.spotifyId, appleId: base.appleId, imageUrl: base.imageUrl,
      transcription: base.transcription)
    let firstSpin = Spin.mockWith(id: "spin-first", audioBlock: nilUrlBlock)

    let laterUrl = URL(string: "https://example.com/later.m4a")!
    let laterSpin = Spin.mockWith(
      id: "spin-later", airtime: Date().addingTimeInterval(300),
      audioBlock: .mockWith(downloadUrl: laterUrl))

    controller.start(with: [firstSpin, laterSpin])
    await downloadManager.waitForCall(laterUrl)
    downloadManager.fireProgress(laterUrl, 0.4)

    #expect(progressUpdates.isEmpty)

    downloadManager.completeDownload(laterUrl)
    controller.stop()
  }

  @Test("a duplicate-id later spin does not inherit the malformed first spin's progress reporting")
  func duplicateFirstSpinIdDoesNotLeakProgressToLaterCopy() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }

    // Pathological schedule: the true first (currently-airing) spin is malformed (nil downloadUrl) AND a
    // later spin carries the SAME id with a real URL. Progress reporting must stay pinned to the airing
    // spin by POSITION, not id — keying on `spin.id` alone would let the later same-id copy masquerade as
    // the airing spin (it is never dropped into knownSpinIDs because the nil-URL first copy returns early
    // before insertion). Build the nil-URL block by hand (mockWith(downloadUrl:) can't force nil).
    let base = AudioBlock.mock
    let nilUrlBlock = AudioBlock(
      id: base.id, title: base.title, artist: base.artist, durationMS: base.durationMS,
      endOfMessageMS: base.endOfMessageMS, beginningOfOutroMS: base.beginningOfOutroMS,
      endOfIntroMS: base.endOfIntroMS, lengthOfOutroMS: base.lengthOfOutroMS, downloadUrl: nil,
      s3Key: base.s3Key, s3BucketName: base.s3BucketName, type: base.type,
      createdAt: base.createdAt, updatedAt: base.updatedAt, album: base.album,
      popularity: base.popularity, youTubeId: base.youTubeId, isrc: base.isrc,
      spotifyId: base.spotifyId, appleId: base.appleId, imageUrl: base.imageUrl,
      transcription: base.transcription)
    let firstSpin = Spin.mockWith(id: "dup", audioBlock: nilUrlBlock)

    let laterUrl = URL(string: "https://example.com/later.m4a")!
    let laterCopy = Spin.mockWith(
      id: "dup", airtime: Date().addingTimeInterval(300),
      audioBlock: .mockWith(downloadUrl: laterUrl))

    controller.start(with: [firstSpin, laterCopy])
    await downloadManager.waitForCall(laterUrl)
    downloadManager.fireProgress(laterUrl, 0.4)

    #expect(progressUpdates.isEmpty)

    downloadManager.completeDownload(laterUrl)
    controller.stop()
  }

  @Test("progress arriving after playback is published is dropped")
  func progressAfterPlaybackPublishedIsDropped() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    // startFrame 0 <= the default latencyFrames (0): the audible-decode trigger, so this both
    // starts the renderer AND publishes playback (fast path).
    controller.simulateDecodeLandedForTesting(startFrame: 0)

    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }
    downloadManager.fireProgress(url, 0.9)

    #expect(progressUpdates.isEmpty)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test(
    "progress after a later spin's boundary crossing is dropped, even if its own download never resolves"
  )
  func progressAfterBoundaryCrossingIsDroppedEvenWithoutAiringSpinResolving() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    // The deadline starts the renderer silently; the airing spin's own download is still in
    // flight (may never resolve). A later spin can still decode early and become audible first —
    // its boundary crossing must retire the airing spin's progress reporting too, or a stale
    // download's progress would regress state backward from `.playing` to `.loading`.
    controller.startRendererIfNeededForTesting()
    controller.simulateSpinBoundaryForTesting(Spin.mockWith(id: "spin-later"))

    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }
    downloadManager.fireProgress(url, 0.9)

    #expect(progressUpdates.isEmpty)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("progress keeps flowing through the deadline-started silent hole")
  func progressFlowsThroughDeadlineStartedHole() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    // The startup deadline starts the renderer with no decode landed yet — playback is NOT
    // published, so progress must keep updating (the host's loading UI must not disappear).
    controller.startRendererIfNeededForTesting()

    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }
    downloadManager.fireProgress(url, 0.8)

    #expect(progressUpdates == [0.8])

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test(
    "progress keeps flowing after the airing spin's own boundary crossing, not just a later spin's")
  func progressFlowsThroughAiringSpinsOwnBoundaryCrossing() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    // The renderer's boundary observer fires for the airing spin's own scheduled position too,
    // independent of whether its decode has landed — that must NOT be treated as proof real audio
    // is playing (the exact original bug this PR fixes). Only a DIFFERENT (later) spin's boundary
    // crossing may retire progress reporting.
    controller.startRendererIfNeededForTesting()
    controller.simulateSpinBoundaryForTesting(spin)

    var progressUpdates: [Float] = []
    controller.onLoadProgress = { progressUpdates.append($0) }
    downloadManager.fireProgress(url, 0.8)

    #expect(progressUpdates == [0.8])

    downloadManager.completeDownload(url)
    controller.stop()
  }
}
