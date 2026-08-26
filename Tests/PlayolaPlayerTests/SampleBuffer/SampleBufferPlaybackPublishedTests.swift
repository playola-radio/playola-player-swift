//  SampleBufferPlaybackPublishedTests.swift
//  PlayolaPlayer
//
//  `onPlaybackStarted` must fire only when audio is actually imminent, not merely when the
//  startup deadline elapses (CHANGELOG 0.21.0-beta.4). If the deadline starts the renderer with
//  no decode landed yet, playback stays pending — published later, either by the first audible
//  decode or by the airing spin's download/decode failing (so the state machine can never sit in
//  `.loading` forever while the renderer runs). See SampleBufferPlaybackController's `onPlaybackStarted`
//  doc comment for the full trigger list.

import Foundation
import Testing

@testable import PlayolaPlayer

/// `.serialized`: each test constructs a real `SampleBufferPlaybackController`, which owns a real
/// `AVSampleBufferRenderSynchronizer`/`AVSampleBufferAudioRenderer` pair (`LiveSampleBufferSink`) — the
/// controller's own doc comment notes this glue "needs real downloads + audio hardware" and is
/// device-verified, not unit-tested, in contrast to `SampleBufferStationRendererTests`, which injects
/// fakes. Swift Testing's default concurrent scheduling ran this suite's 21 real-controller instances
/// alongside the rest of the target's tests and reproducibly stalled the whole `swift test` process for
/// ~270s on CircleCI's headless macOS runner (never locally) — serializing keeps at most one real sink
/// alive at a time.
@MainActor
@Suite(.serialized)
struct SampleBufferPlaybackPublishedTests {
  private func makeController(_ downloadManager: ProgressCapturingDownloadManager)
    -> SampleBufferPlaybackController
  {
    SampleBufferPlaybackController(anchorDate: Date(), fileDownloadManager: downloadManager)
  }

  @Test("audible decode before the deadline publishes playback once, fast path unchanged")
  func audibleDecodeBeforeDeadlinePublishesOnce() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    // startFrame 0 <= the default latencyFrames (0): audible.
    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(startedCount == 1)

    // A later decode landing again must not re-fire it.
    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(startedCount == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("the deadline alone does not publish playback")
  func deadlineAloneDoesNotPublish() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    #expect(startedCount == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("an audible decode landing after the deadline publishes playback exactly once")
  func audibleDecodeAfterDeadlinePublishesOnce() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    #expect(startedCount == 0)

    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(startedCount == 1)

    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(startedCount == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("an upcoming (non-audible) spin's decode does not publish playback")
  func nonAudibleDecodeDoesNotPublish() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()

    // startFrame well above the default latencyFrames (0): a future spin, not audible yet.
    controller.simulateDecodeLandedForTesting(startFrame: 999_999)
    #expect(startedCount == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a later spin's decode within the audible-position window does not publish playback")
  func laterSpinDecodeWithinAudibleWindowDoesNotPublish() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()

    // startFrame 0 satisfies the audible-position gate, but this decode belongs to a DIFFERENT
    // (later) spin, not the airing one — position alone must not be mistaken for the airing
    // spin's own decode (a later spin scheduled within the latency-compensation window on a
    // high-latency route, e.g. AirPlay, could otherwise decode first and publish early).
    controller.simulateDecodeLandedForTesting(spinID: "spin-later", startFrame: 0)
    #expect(startedCount == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("the airing spin's real download failure after the deadline publishes playback")
  func realAiringSpinDownloadFailureAfterDeadlinePublishes() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()

    // Proves the real download()-catch wiring reaches onPlaybackStarted (not just the test
    // seam below) — awaits the callback itself instead of guessing at Task scheduling timing.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      controller.onPlaybackStarted = { continuation.resume() }
      downloadManager.failDownload(url)
    }

    controller.stop()
  }

  @Test("a simulated airing-spin failure after the deadline publishes playback")
  func simulatedAiringSpinFailureAfterDeadlinePublishes() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    #expect(startedCount == 0)

    controller.simulateSpinFailureForTesting(spinID: "spin-first")
    #expect(startedCount == 1)

    // A subsequent audible decode must not re-fire it.
    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(startedCount == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a simulated airing-spin failure before the deadline defers publish to the deadline")
  func simulatedAiringSpinFailureBeforeDeadlineDefersPublish() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.simulateSpinFailureForTesting(spinID: "spin-first")
    // Audio behavior must not change: the renderer (and therefore the publish it gates) still
    // waits for the deadline, even though the airing spin has already failed.
    #expect(startedCount == 0)

    controller.startRendererIfNeededForTesting()
    #expect(startedCount == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test(
    "a future first spin's failure defers publish until its own boundary crossing, not immediately")
  func futureFirstSpinFailureBeforeBoundaryDefersUntilBoundaryCrossing() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedSpinIDs: [String] = []
    controller.onSpinStarted = { startedSpinIDs.append($0.id) }
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    // Schedule.current can hand back a first spin that hasn't started airing yet — its download can
    // still fail well ahead of its own scheduled position.
    let spin = Spin.mockWith(
      id: "spin-first", airtime: Date().addingTimeInterval(300),
      audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    controller.simulateSpinFailureForTesting(spinID: spin.id)
    // The failure landed 5 minutes before this spin's own scheduled position — publishing now would
    // show `.playing` for audio that isn't due for another 5 minutes.
    #expect(startedCount == 0)

    // Wall-clock time reaching this spin's own scheduled boundary is the real signal that playback
    // was due to start — the failed spin never gets real audio, so this publishes via
    // `onPlaybackStarted`, not `onSpinStarted`.
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(startedCount == 1)
    #expect(startedSpinIDs.isEmpty)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test(
    "a future first spin's failure before the deadline still defers publish when the deadline starts the renderer"
  )
  func futureFirstSpinFailureBeforeDeadlineDefersAtDeadline() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedSpinIDs: [String] = []
    controller.onSpinStarted = { startedSpinIDs.append($0.id) }
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(
      id: "spin-first", airtime: Date().addingTimeInterval(300),
      audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    // The failure races ahead of the deadline this time (renderer not started yet).
    controller.simulateSpinFailureForTesting(spinID: spin.id)
    #expect(startedCount == 0)

    // The deadline starting the renderer must not publish either — this spin's own scheduled
    // position is still 5 minutes out, so audio is not yet imminent.
    controller.startRendererIfNeededForTesting()
    #expect(startedCount == 0)

    controller.simulateSpinBoundaryForTesting(spin)
    #expect(startedCount == 1)
    #expect(startedSpinIDs.isEmpty)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a stale frozen-position check does not defer a first spin's failure past its own airtime")
  func staleFirstSpinFailureBeforeDeadlinePublishesOnceAirtimeHasPassed() async {
    let downloadManager = ProgressCapturingDownloadManager()
    // Anchor 2s in the past and schedule airtime 1s after the anchor, so real "now" has already
    // passed this spin's airtime by ~1s — but the ingest-time snapshot (`mapper.frame(for: airtime)`
    // relative to `latencyFrames`) still reads "not yet due," since the spin's frame position is
    // positive at ingest and no wall-clock time is baked into that snapshot.
    let anchorDate = Date().addingTimeInterval(-2)
    let controller = SampleBufferPlaybackController(
      anchorDate: anchorDate, fileDownloadManager: downloadManager)
    var startedSpinIDs: [String] = []
    controller.onSpinStarted = { startedSpinIDs.append($0.id) }
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(
      id: "spin-first", airtime: anchorDate.addingTimeInterval(1),
      audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    // The failure races ahead of the deadline (renderer not started yet).
    controller.simulateSpinFailureForTesting(spinID: spin.id)
    #expect(startedCount == 0)

    // By the time the deadline starts the renderer, real time has already passed this spin's
    // airtime — publish now rather than waiting for a boundary crossing that already happened in
    // the past (there is nothing left to cross).
    controller.startRendererIfNeededForTesting()
    #expect(startedCount == 1)
    #expect(startedSpinIDs.isEmpty)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  /// mockWith(downloadUrl:) can't force a genuinely-nil URL (nil == omitted), so build it by hand.
  private func nilURLSpin(id: String) -> Spin {
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
    return Spin.mockWith(id: id, audioBlock: nilUrlBlock)
  }

  @Test("a malformed airing spin (nil downloadUrl) still publishes playback at the deadline")
  func malformedAiringSpinPublishesAtDeadline() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    // Production (PlayolaStationPlayer.validateSpinForScheduling) never lets a malformed airing
    // spin reach the controller — this exercises the controller's own defense in depth: no
    // download/decode task exists for this spin, so the deadline is the ONLY thing that can ever
    // unstick `.loading` here.
    controller.start(with: [nilURLSpin(id: "spin-first")])

    controller.startRendererIfNeededForTesting()
    #expect(startedCount == 1)

    controller.stop()
  }

  @Test("the airing spin's own boundary crossing before decode does not publish playback")
  func airingSpinOwnBoundaryDoesNotPublish() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    // The renderer's boundary observer fires for the airing spin's own scheduled position too,
    // independent of whether its decode has landed — this must NOT be treated as proof real audio
    // is playing (that's exactly the original bug this PR fixes).
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(startedCount == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("an audible decode after the airing spin's own boundary crossing still publishes playback")
  func audibleDecodeAfterAiringSpinsOwnBoundaryStillPublishes() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    // The airing spin's own (erroneous, decode-not-landed) boundary crossing must not poison the
    // later, legitimate publish trigger once its decode actually lands.
    controller.simulateSpinBoundaryForTesting(spin)
    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(startedCount == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test(
    "the airing spin's own boundary crossing after an audible decode is not re-forwarded to onSpinStarted"
  )
  func airingSpinOwnBoundaryAfterAudibleDecodeIsNotReforwarded() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedSpinIDs: [String] = []
    controller.onSpinStarted = { startedSpinIDs.append($0.id) }
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    // Audible decode publishes first via `onPlaybackStarted`.
    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(startedCount == 1)

    // The same spin's own boundary crossing arrives afterward (purely position-based, independent
    // of the decode/publish sequencing above) — it must not re-publish the same spin a second time
    // through the OTHER callback.
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(startedSpinIDs.isEmpty)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("the airing spin's own boundary crossing before decode is not forwarded to onSpinStarted")
  func airingSpinOwnBoundaryIsNotForwardedToOnSpinStarted() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedSpinIDs: [String] = []
    controller.onSpinStarted = { startedSpinIDs.append($0.id) }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    // The renderer's boundary observer fires purely from the spin's scheduled position — it has no
    // idea whether the airing spin's own decode has landed. Forwarding this to the owner would
    // reintroduce the silent pre-decode `.playing` bug via a different callback than the one this
    // PR guards (`onPlaybackStarted`).
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(startedSpinIDs.isEmpty)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a first spin whose decode lands before its own airtime still publishes at its boundary")
  func firstSpinDecodedEarlyStillPublishesAtOwnBoundary() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedSpinIDs: [String] = []
    controller.onSpinStarted = { startedSpinIDs.append($0.id) }
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    // Schedule.current can hand back a first spin that hasn't started yet (nothing currently on
    // air) — its decode can land well before its own airtime arrives.
    let spin = Spin.mockWith(
      id: "spin-first", airtime: Date().addingTimeInterval(300),
      audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()

    // Decode lands early, well beyond the audible-position window — correctly not published yet.
    controller.simulateDecodeLandedForTesting(startFrame: 999_999)
    #expect(startedCount == 0)
    #expect(startedSpinIDs.isEmpty)

    // Time passes; the boundary fires once the spin's scheduled position arrives. Since its decode
    // already landed, this is real audio becoming audible and must publish — the boundary is not
    // always spurious for the airing spin, only when no decode has landed for it at all yet.
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(startedSpinIDs == ["spin-first"])

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test(
    "a first spin whose boundary fires before its decode lands still publishes once decode arrives")
  func firstSpinBoundaryBeforeDecodeStillPublishesWhenDecodeLandsLate() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedSpinIDs: [String] = []
    controller.onSpinStarted = { startedSpinIDs.append($0.id) }
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    // Schedule.current can hand back a first spin that hasn't started yet (nothing currently on
    // air) — decode-ahead is driven by the renderer's position, so a slow decode can still be in
    // flight when wall-clock time reaches the spin's own scheduled boundary.
    let spin = Spin.mockWith(
      id: "spin-first", airtime: Date().addingTimeInterval(300),
      audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()

    // The boundary fires before any decode has landed — correctly dropped, same as the
    // still-unresolved-airing-spin case.
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(startedSpinIDs.isEmpty)
    #expect(startedCount == 0)

    // Decode finally lands, well beyond the audible-position window. The position check alone
    // would drop this forever (the spin's fixed scheduled position never becomes "audible" by
    // that arithmetic), but the boundary already told us real time passed this spin's airtime —
    // so this decode landing is the only remaining signal that will ever publish for it.
    controller.simulateDecodeLandedForTesting(startFrame: 999_999)
    #expect(startedCount == 1)

    // A second decode landing must not double-publish.
    controller.simulateDecodeLandedForTesting(startFrame: 999_999)
    #expect(startedCount == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a later spin's boundary crossing is forwarded to onSpinStarted")
  func laterSpinBoundaryIsForwardedToOnSpinStarted() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedSpinIDs: [String] = []
    controller.onSpinStarted = { startedSpinIDs.append($0.id) }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    controller.simulateSpinBoundaryForTesting(Spin.mockWith(id: "spin-later"))
    #expect(startedSpinIDs == ["spin-later"])

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test(
    "a later spin's boundary crossing publishes playback even if the airing spin's own download never resolves"
  )
  func laterSpinBoundaryPublishesEvenWithoutAiringSpinResolving() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)

    controller.startRendererIfNeededForTesting()
    controller.simulateSpinBoundaryForTesting(Spin.mockWith(id: "spin-later"))

    downloadManager.completeDownload(url)
    controller.stop()

    // onSpinStarted (not onPlaybackStarted) is the owner's `.playing` signal for this later spin,
    // so onPlaybackStarted correctly stays unfired — only progress retirement is asserted here.
    #expect(startedCount == 0)
  }

  @Test("an upcoming spin's simulated failure does not publish playback")
  func upcomingSpinSimulatedFailureDoesNotPublish() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    var startedCount = 0
    controller.onPlaybackStarted = { startedCount += 1 }

    let firstUrl = URL(string: "https://example.com/first.m4a")!
    let firstSpin = Spin.mockWith(id: "spin-first", audioBlock: .mockWith(downloadUrl: firstUrl))
    controller.start(with: [firstSpin])
    await downloadManager.waitForCall(firstUrl)

    controller.startRendererIfNeededForTesting()
    controller.simulateSpinFailureForTesting(spinID: "spin-upcoming")
    #expect(startedCount == 0)

    downloadManager.completeDownload(firstUrl)
    controller.stop()
  }
}
