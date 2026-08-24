//  SampleBufferProgressGenerationTests.swift
//  PlayolaPlayer
//
//  A superseding play() must silence progress from the PREVIOUS play()'s controller — same
//  generation discipline as onSpinStarted/onPlaybackStarted/onRendererFailed (see CHANGELOG
//  0.21.0-beta.3). Pauses the second play()'s schedule fetch mid-flight (after the generation
//  bump, before the old controller is torn down) so the old controller is still alive when the
//  stale progress fires — proving the generation gate, not weak-self teardown, is what silences it.

import Foundation
import Testing

@testable import PlayolaPlayer

/// One-shot rendezvous: lets a test block a specific in-flight async call (the second
/// station's schedule fetch) until it has genuinely arrived, then release it on demand.
private actor RequestPauseGate {
  private var resumeContinuation: CheckedContinuation<Void, Never>?
  private var arrivedContinuation: CheckedContinuation<Void, Never>?
  private var hasArrived = false

  func waitForArrival() async {
    if hasArrived { return }
    await withCheckedContinuation { arrivedContinuation = $0 }
  }

  /// Called from inside the paused request: signal arrival, then block until `resume()`.
  func pauseHere() async {
    hasArrived = true
    arrivedContinuation?.resume()
    arrivedContinuation = nil
    await withCheckedContinuation { resumeContinuation = $0 }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

@MainActor
private final class LoadingProgressRecorder: PlayolaStationPlayerDelegate {
  var loadingValues: [Float] = []

  nonisolated func player(
    _ player: PlayolaStationPlayer, playerStateDidChange state: PlayolaStationPlayer.State
  ) {
    guard case .loading(let progress) = state else { return }
    MainActor.assumeIsolated { loadingValues.append(progress) }
  }
}

@MainActor
struct SampleBufferProgressGenerationTests {
  private func scheduleData(for spin: Spin) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(.iso8601Full)
    return try encoder.encode([spin])
  }

  @Test("a superseding play() silences the old controller's progress")
  func supersededGenerationProgressIsGated() async throws {
    let downloadManager = ProgressCapturingDownloadManager()
    let session = MockURLSession()

    // Explicit airtime near "now": Schedule.mock's default airtime is a fixed date baked into
    // MockSchedule.json, which is stale by the time tests run (its endtime is long past, so
    // Schedule.current() would filter it out and play() would throw "No available spins to play").
    let now = Date()
    let firstUrl = URL(string: "https://example.com/first.m4a")!
    let firstSpin = Spin.mockWith(
      id: "spin-first", airtime: now.addingTimeInterval(-5), stationId: "station-1",
      audioBlock: .mockWith(downloadUrl: firstUrl))
    session.addResponse(data: try scheduleData(for: firstSpin), statusCode: 200)

    // station-1's own 20s poll loop fires ONE eager fetch immediately after play() returns (before its
    // first sleep) — a stray FIFO consumer racing this test's own requests. Queue a filler response to
    // absorb it so it can never accidentally consume the response meant for station-2 below.
    session.addResponse(data: try scheduleData(for: firstSpin), statusCode: 200)

    let secondUrl = URL(string: "https://example.com/second.m4a")!
    let secondSpin = Spin.mockWith(
      id: "spin-second", airtime: now.addingTimeInterval(-5), stationId: "station-2",
      audioBlock: .mockWith(downloadUrl: secondUrl))
    session.addResponse(data: try scheduleData(for: secondSpin), statusCode: 200)

    let player = PlayolaStationPlayer(fileDownloadManager: downloadManager, urlSession: session)
    player.configure(authProvider: MockAuthProvider(), renderBackend: .sampleBuffer)
    let recorder = LoadingProgressRecorder()
    player.delegate = recorder

    try await player.play(stationId: "station-1")
    await downloadManager.waitForCall(firstUrl)

    let gate = RequestPauseGate()
    session.beforeResponse = { request in
      guard request.url?.path.contains("station-2") == true else { return }
      await gate.pauseHere()
    }

    let secondPlay = Task { try await player.play(stationId: "station-2") }
    await gate.waitForArrival()

    // The generation bump happens synchronously at the top of play(), before this fetch's
    // await — so by the time the fetch has arrived here, station-1's controller is superseded
    // but has NOT been torn down yet (that happens after the fetch resolves). Firing its stale
    // progress now proves the generation gate — not a deallocated controller — silences it.
    downloadManager.fireProgress(firstUrl, 0.66)
    #expect(!recorder.loadingValues.contains(0.66))

    await gate.resume()
    try await secondPlay.value

    downloadManager.completeDownload(firstUrl)
    downloadManager.completeDownload(secondUrl)
    player.stop()
  }
}
