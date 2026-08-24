//  SampleBufferRendererFailureTests.swift
//  PlayolaPlayer
//
//  A terminal renderer failure publishes .error and tears the controller down. It must ALSO bump the
//  play generation, so a late onLoadProgress callback from the same (now-dead) controller — whose stop()
//  Task cancellation does not guarantee its download progress handler won't fire once more — cannot pass
//  the generation gate and silently regress .error back to .loading (PR #110 Codex review, P1 #1).

import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct SampleBufferRendererFailureTests {
  private func scheduleData(for spin: Spin) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(.iso8601Full)
    return try encoder.encode([spin])
  }

  @Test(
    "a late progress callback after a renderer failure does not regress .error back to .loading")
  func lateProgressAfterRendererFailureDoesNotRegressError() async throws {
    let downloadManager = ProgressCapturingDownloadManager()
    let session = MockURLSession()

    let now = Date()
    // A long endOfMessageMS keeps the airing spin's endtime in the future for the whole test — the
    // default mock block is only ~8.3s, leaving ~3.3s against this live clock that a loaded CI box can
    // blow through, filtering the spin out mid-test (flaky "No available spins"). Matches the fix in
    // SampleBufferProgressGenerationTests.
    let url = URL(string: "https://example.com/first.m4a")!
    let spin = Spin.mockWith(
      id: "spin-first", airtime: now.addingTimeInterval(-5), stationId: "station-1",
      audioBlock: .mockWith(endOfMessageMS: 600_000, downloadUrl: url))
    session.addResponse(data: try scheduleData(for: spin), statusCode: 200)
    // station-1's 20s poll loop fires one eager fetch right after play() returns; absorb it.
    session.addResponse(data: try scheduleData(for: spin), statusCode: 200)

    let player = PlayolaStationPlayer(fileDownloadManager: downloadManager, urlSession: session)
    player.configure(authProvider: MockAuthProvider(), renderBackend: .sampleBuffer)

    try await player.play(stationId: "station-1")
    await downloadManager.waitForCall(url)

    let controller = try #require(player.sampleBufferController)

    controller.onRendererFailed?(StationPlayerError.playbackError("boom"))
    guard case .error = player.state else {
      Issue.record("Expected .error after renderer failure, got \(player.state)")
      return
    }

    // Simulate a late progress callback landing after teardown: same controller, and — unless the
    // failure bumped the generation — the same generation the onLoadProgress closure was gated on.
    // It must NOT overwrite .error with .loading.
    controller.onLoadProgress?(0.5)
    guard case .error = player.state else {
      Issue.record(
        "Expected state to stay .error after a late progress callback, got \(player.state)")
      return
    }

    downloadManager.completeDownload(url)
    player.stop()
  }
}
