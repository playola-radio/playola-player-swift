//  SampleBufferLateDecodeRecoveryTests.swift
//  PlayolaPlayer
//
//  First-play "loaded, then dead air" fix: when the startup deadline starts the renderer before the
//  airing spin's decode lands, the queue holds up to the full enqueue horizon of silence. The moment
//  playback becomes publishable via that late decode (or its trusted boundary crossing), the controller
//  must ask the renderer to discard the queued silence and re-anchor to the live playhead — and the
//  catch-up decode must start from the playhead (not the ingest-time frozen offset) and cover the
//  refill span, or the refill would mix silence right back in.

import Foundation
import Testing

@testable import PlayolaPlayer

struct CatchUpDecodeWindowTests {
  private let readAhead: Int64 = 96_000  // 2s @ 48k
  private let catchUpSpan: Int64 = 192_000  // horizon + decode lead, 4s @ 48k

  @Test("no playhead (renderer not started): decode from the ingest offset, normal span")
  func noPlayheadUsesIngestOffset() {
    let window = SampleBufferPlaybackController.catchUpDecodeWindow(
      ingestOffset: 1_000, playheadFrame: nil, startFrame: 0,
      readAheadFrames: readAhead, catchUpSpanFrames: catchUpSpan)
    #expect(window.offset == 1_000)
    #expect(window.decodeThrough == 1_000 + readAhead)
  }

  @Test("playhead at/behind the ingest offset: decode from the ingest offset, normal span")
  func playheadBehindIngestOffsetUsesIngestOffset() {
    // A future spin (startFrame well ahead of the playhead) must keep decoding from its start.
    let window = SampleBufferPlaybackController.catchUpDecodeWindow(
      ingestOffset: 0, playheadFrame: 96_000, startFrame: 480_000,
      readAheadFrames: readAhead, catchUpSpanFrames: catchUpSpan)
    #expect(window.offset == 0)
    #expect(window.decodeThrough == readAhead)
  }

  @Test("playhead past the ingest offset: decode from the playhead with the catch-up span")
  func playheadAheadOfIngestOffsetCatchesUp() {
    // Deadline-started renderer ran silently for ~8s past the frozen ingest offset: decoding from
    // the frozen offset would produce a window entirely behind the playhead (mixes to silence).
    let window = SampleBufferPlaybackController.catchUpDecodeWindow(
      ingestOffset: 96_000, playheadFrame: 480_000, startFrame: 0,
      readAheadFrames: readAhead, catchUpSpanFrames: catchUpSpan)
    #expect(window.offset == 480_000)
    #expect(window.decodeThrough == 480_000 + catchUpSpan)
  }
}

/// `.serialized`: each test constructs a real `SampleBufferPlaybackController` (real
/// `LiveSampleBufferSink`) — same CI-stall rationale as `SampleBufferPlaybackPublishedTests`.
@MainActor
@Suite(.serialized)
struct SampleBufferLateDecodeRecoveryTests {
  private func makeController(_ downloadManager: ProgressCapturingDownloadManager)
    -> SampleBufferPlaybackController
  {
    SampleBufferPlaybackController(anchorDate: Date(), fileDownloadManager: downloadManager)
  }

  private func startAiringSpin(
    _ controller: SampleBufferPlaybackController,
    _ downloadManager: ProgressCapturingDownloadManager,
    airtime: Date = Date()
  ) async -> (spin: Spin, url: URL) {
    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(
      id: "spin-first", airtime: airtime, audioBlock: .mockWith(downloadUrl: url))
    controller.start(with: [spin])
    await downloadManager.waitForCall(url)
    return (spin, url)
  }

  @Test("an audible decode after the deadline discards the queued silence exactly once")
  func audibleDecodeAfterDeadlineRecoversOnce() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    let (_, url) = await startAiringSpin(controller, downloadManager)

    controller.startRendererIfNeededForTesting()
    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(controller.lateDecodeRecoveriesForTesting == 1)

    // A repeat decode landing must not flush again — playback is already published.
    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(controller.lateDecodeRecoveriesForTesting == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("an audible decode before the deadline does not discard anything")
  func audibleDecodeBeforeDeadlineDoesNotRecover() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    let (_, url) = await startAiringSpin(controller, downloadManager)

    // Fast path: the decode itself starts the renderer — no silence was ever queued.
    controller.simulateDecodeLandedForTesting(startFrame: 0)
    #expect(controller.lateDecodeRecoveriesForTesting == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a decode landing after the airing spin's own boundary crossed discards the queued silence")
  func decodeAfterBoundaryCrossingRecovers() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    let (spin, url) = await startAiringSpin(
      controller, downloadManager, airtime: Date().addingTimeInterval(300))

    controller.startRendererIfNeededForTesting()
    // Boundary fires before any decode — dropped, but remembered.
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(controller.lateDecodeRecoveriesForTesting == 0)

    // The late decode is the only remaining publish signal — silence has been queuing since the
    // deadline start, so it must also trigger the discard.
    controller.simulateDecodeLandedForTesting(startFrame: 999_999)
    #expect(controller.lateDecodeRecoveriesForTesting == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("an early-decoded future first spin discards queued silence at its boundary crossing")
  func earlyDecodedFutureSpinRecoversAtBoundary() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    let (spin, url) = await startAiringSpin(
      controller, downloadManager, airtime: Date().addingTimeInterval(300))

    controller.startRendererIfNeededForTesting()
    controller.playheadFrameOverrideForTesting = 0
    // Decode lands well before this spin's own airtime — correctly not published, nothing discarded.
    controller.simulateDecodeLandedForTesting(startFrame: 999_999)
    #expect(controller.lateDecodeRecoveriesForTesting == 0)

    // The boundary crosses while the playhead is still within one enqueue horizon of the decode
    // landing, so the spin's opening region may sit in the queue as silence (enqueued before its
    // snapshot installed) — the trusted crossing discards and refills with the real audio.
    controller.playheadFrameOverrideForTesting = 48_000
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(controller.lateDecodeRecoveriesForTesting == 1)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a future first spin decoded long before its boundary does not flush at the crossing")
  func longSinceDecodedFutureSpinDoesNotFlushAtBoundary() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    let (spin, url) = await startAiringSpin(
      controller, downloadManager, airtime: Date().addingTimeInterval(300))

    controller.startRendererIfNeededForTesting()
    controller.playheadFrameOverrideForTesting = 0
    controller.simulateDecodeLandedForTesting(startFrame: 999_999)
    #expect(controller.lateDecodeRecoveriesForTesting == 0)

    // Minutes of silent running later, the playhead has traveled far past anything enqueued before
    // the snapshot installed — everything queued now holds the real opening audio, and flushing it
    // at the boundary would only risk an audible glitch. Publish still happens.
    controller.playheadFrameOverrideForTesting = 10_000_000
    controller.simulateSpinBoundaryForTesting(spin)
    #expect(controller.lateDecodeRecoveriesForTesting == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a decode landing before the renderer ever started never flushes at the boundary")
  func decodeBeforeRendererStartDoesNotFlushAtBoundary() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    let (spin, url) = await startAiringSpin(
      controller, downloadManager, airtime: Date().addingTimeInterval(300))

    // Decode lands first; the renderer starts afterwards with the snapshot already installed, so
    // every frame it ever enqueues for this spin's region is mixed from the real audio.
    controller.playheadFrameOverrideForTesting = 0
    controller.simulateDecodeLandedForTesting(startFrame: 999_999)
    controller.startRendererIfNeededForTesting()

    controller.simulateSpinBoundaryForTesting(spin)
    #expect(controller.lateDecodeRecoveriesForTesting == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("the airing spin's failure fallback does not discard (there is no audio to refill)")
  func airingSpinFailureDoesNotRecover() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    let (_, url) = await startAiringSpin(controller, downloadManager)

    controller.startRendererIfNeededForTesting()
    controller.simulateSpinFailureForTesting(spinID: "spin-first")
    #expect(controller.lateDecodeRecoveriesForTesting == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }

  @Test("a later spin's decode or boundary crossing does not discard queued audio")
  func laterSpinEventsDoNotRecover() async {
    let downloadManager = ProgressCapturingDownloadManager()
    let controller = makeController(downloadManager)
    let (_, url) = await startAiringSpin(controller, downloadManager)

    controller.startRendererIfNeededForTesting()
    // A later spin's boundary crossing means real audio is (or is about to be) playing — flushing
    // the queue here would cut into it.
    controller.simulateDecodeLandedForTesting(spinID: "spin-later", startFrame: 0)
    controller.simulateSpinBoundaryForTesting(Spin.mockWith(id: "spin-later"))
    #expect(controller.lateDecodeRecoveriesForTesting == 0)

    downloadManager.completeDownload(url)
    controller.stop()
  }
}
