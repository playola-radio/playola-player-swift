//  SampleBufferMalformedSpinTests.swift
//  PlayolaPlayer
//
//  The sample-buffer backend must match the legacy path's first-spin validation: if the currently-airing
//  spin has no downloadUrl (malformed schedule), play() fails with .error instead of creating a controller
//  that silently renders dead air with the wrong metadata (PR #110 Codex challenge, pre-existing P1).

import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct SampleBufferMalformedSpinTests {
  private func scheduleData(for spin: Spin) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(.iso8601Full)
    return try encoder.encode([spin])
  }

  private func emptyScheduleData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(.iso8601Full)
    return try encoder.encode([Spin]())
  }

  /// mockWith(downloadUrl:) can't force a genuinely-nil URL (nil == omitted), so build the block by hand.
  /// A long endOfMessageMS keeps the airing spin "current" for the whole test against the live clock.
  private func nilUrlSpin(id: String, airtime: Date) -> Spin {
    let base = AudioBlock.mock
    let nilUrlBlock = AudioBlock(
      id: base.id, title: base.title, artist: base.artist, durationMS: base.durationMS,
      endOfMessageMS: 600_000, beginningOfOutroMS: base.beginningOfOutroMS,
      endOfIntroMS: base.endOfIntroMS, lengthOfOutroMS: base.lengthOfOutroMS, downloadUrl: nil,
      s3Key: base.s3Key, s3BucketName: base.s3BucketName, type: base.type,
      createdAt: base.createdAt, updatedAt: base.updatedAt, album: base.album,
      popularity: base.popularity, youTubeId: base.youTubeId, isrc: base.isrc,
      spotifyId: base.spotifyId, appleId: base.appleId, imageUrl: base.imageUrl,
      transcription: base.transcription)
    return Spin.mockWith(id: id, airtime: airtime, stationId: "station-1", audioBlock: nilUrlBlock)
  }

  @Test("a malformed currently-airing spin (nil downloadUrl) fails play() with .error")
  func malformedAiringSpinFailsWithError() async throws {
    let downloadManager = ProgressCapturingDownloadManager()
    let session = MockURLSession()

    let now = Date()
    let spin = nilUrlSpin(id: "spin-first", airtime: now.addingTimeInterval(-5))
    session.addResponse(data: try scheduleData(for: spin), statusCode: 200)

    let player = PlayolaStationPlayer(fileDownloadManager: downloadManager, urlSession: session)
    player.configure(authProvider: MockAuthProvider(), renderBackend: .sampleBuffer)

    await #expect(throws: StationPlayerError.self) {
      try await player.play(stationId: "station-1")
    }

    guard case .error = player.state else {
      Issue.record("Expected .error for a malformed airing spin, got \(player.state)")
      return
    }

    // No controller should have been created: validation must fail before the render pipeline is built.
    #expect(player.sampleBufferController == nil)

    player.stop()
  }

  @Test(
    "switching to a malformed station tears down the previous controller instead of leaving it live"
  )
  func malformedSecondStationTearsDownPreviousController() async throws {
    let downloadManager = ProgressCapturingDownloadManager()
    let session = MockURLSession()
    let now = Date()

    // Station A is valid and starts playing (creating a live controller).
    let urlA = URL(string: "https://example.com/a.m4a")!
    let spinA = Spin.mockWith(
      id: "spin-a", airtime: now.addingTimeInterval(-5), stationId: "station-a",
      audioBlock: .mockWith(endOfMessageMS: 600_000, downloadUrl: urlA))
    session.addResponse(data: try scheduleData(for: spinA), statusCode: 200)
    // station-a's poll loop fires one eager fetch right after play() returns; absorb it.
    session.addResponse(data: try scheduleData(for: spinA), statusCode: 200)

    // Station B's airing spin is malformed (nil downloadUrl): the switch must fail validation.
    let spinB = nilUrlSpin(id: "spin-b", airtime: now.addingTimeInterval(-5))
    session.addResponse(data: try scheduleData(for: spinB), statusCode: 200)

    let player = PlayolaStationPlayer(fileDownloadManager: downloadManager, urlSession: session)
    player.configure(authProvider: MockAuthProvider(), renderBackend: .sampleBuffer)

    try await player.play(stationId: "station-a")
    await downloadManager.waitForCall(urlA)
    #expect(player.sampleBufferController != nil)

    // Switching to the malformed station must fail — and in doing so tear down station A's controller,
    // not leave it silently rendering audio while state reads .error.
    await #expect(throws: StationPlayerError.self) {
      try await player.play(stationId: "station-b")
    }

    guard case .error = player.state else {
      Issue.record("Expected .error after switching to a malformed station, got \(player.state)")
      return
    }
    #expect(player.sampleBufferController == nil)

    downloadManager.completeDownload(urlA)
    player.stop()
  }

  @Test("switching to a station with no current spins tears down the previous controller")
  func noCurrentSpinsSecondStationTearsDownPreviousController() async throws {
    let downloadManager = ProgressCapturingDownloadManager()
    let session = MockURLSession()
    let now = Date()

    let urlA = URL(string: "https://example.com/a.m4a")!
    let spinA = Spin.mockWith(
      id: "spin-a", airtime: now.addingTimeInterval(-5), stationId: "station-a",
      audioBlock: .mockWith(endOfMessageMS: 600_000, downloadUrl: urlA))
    session.addResponse(data: try scheduleData(for: spinA), statusCode: 200)
    session.addResponse(data: try scheduleData(for: spinA), statusCode: 200)

    // Station B's schedule has no current spins → play() throws "No available spins" at the outer guard,
    // BEFORE the sample-buffer helper. The previous controller must still be torn down, not left live.
    session.addResponse(data: try emptyScheduleData(), statusCode: 200)

    let player = PlayolaStationPlayer(fileDownloadManager: downloadManager, urlSession: session)
    player.configure(authProvider: MockAuthProvider(), renderBackend: .sampleBuffer)

    try await player.play(stationId: "station-a")
    await downloadManager.waitForCall(urlA)
    #expect(player.sampleBufferController != nil)

    await #expect(throws: StationPlayerError.self) {
      try await player.play(stationId: "station-b")
    }

    guard case .error = player.state else {
      Issue.record("Expected .error after switching to an empty station, got \(player.state)")
      return
    }
    #expect(player.sampleBufferController == nil)

    downloadManager.completeDownload(urlA)
    player.stop()
  }
}
