//
//  AiringTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 6/27/26.
//

import Foundation
import Testing

@testable import PlayolaCore

struct AiringTests {
  private static let airingWithOnAirWindowJSON = """
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "episodeId": "22222222-2222-2222-2222-222222222222",
        "stationId": "33333333-3333-3333-3333-333333333333",
        "airtime": "2025-02-15T15:00:00.000Z",
        "startTime": "2025-02-15T15:00:12.000Z",
        "endTime": "2025-02-15T15:42:30.000Z",
        "createdAt": "2025-02-14T10:00:00.000Z",
        "updatedAt": "2025-02-14T10:00:00.000Z"
    }
    """

  private static let airingWithoutOnAirWindowJSON = """
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "episodeId": "22222222-2222-2222-2222-222222222222",
        "stationId": "33333333-3333-3333-3333-333333333333",
        "airtime": "2025-02-15T15:00:00.000Z",
        "createdAt": "2025-02-14T10:00:00.000Z",
        "updatedAt": "2025-02-14T10:00:00.000Z"
    }
    """

  @Test("Airing decodes startTime and endTime from JSON")
  func testAiringDecodesOnAirWindow() throws {
    let decoder = JSONDecoderWithIsoFull()
    let airing = try decoder.decode(
      Airing.self, from: Self.airingWithOnAirWindowJSON.data(using: .utf8)!)

    let expectedStart = DateFormatter.iso8601Full.date(from: "2025-02-15T15:00:12.000Z")
    let expectedEnd = DateFormatter.iso8601Full.date(from: "2025-02-15T15:42:30.000Z")

    #expect(airing.startTime == expectedStart)
    #expect(airing.endTime == expectedEnd)
    // airtime remains the nominal slot, independent of the real on-air window
    #expect(airing.airtime == DateFormatter.iso8601Full.date(from: "2025-02-15T15:00:00.000Z"))
  }

  @Test("Airing decodes with startTime and endTime absent (backward compatible)")
  func testAiringDecodesWithoutOnAirWindow() throws {
    let decoder = JSONDecoderWithIsoFull()
    let airing = try decoder.decode(
      Airing.self, from: Self.airingWithoutOnAirWindowJSON.data(using: .utf8)!)

    #expect(airing.startTime == nil)
    #expect(airing.endTime == nil)
  }

  @Test("Airing decodes with only startTime present (fields are independently optional)")
  func testAiringDecodesWithOnlyStartTime() throws {
    let json = """
      {
          "id": "11111111-1111-1111-1111-111111111111",
          "episodeId": "22222222-2222-2222-2222-222222222222",
          "stationId": "33333333-3333-3333-3333-333333333333",
          "airtime": "2025-02-15T15:00:00.000Z",
          "startTime": "2025-02-15T15:00:12.000Z",
          "createdAt": "2025-02-14T10:00:00.000Z",
          "updatedAt": "2025-02-14T10:00:00.000Z"
      }
      """
    let decoder = JSONDecoderWithIsoFull()
    let airing = try decoder.decode(Airing.self, from: json.data(using: .utf8)!)

    #expect(airing.startTime == DateFormatter.iso8601Full.date(from: "2025-02-15T15:00:12.000Z"))
    #expect(airing.endTime == nil)
  }

  @Test("Airing decodes with only endTime present (fields are independently optional)")
  func testAiringDecodesWithOnlyEndTime() throws {
    let json = """
      {
          "id": "11111111-1111-1111-1111-111111111111",
          "episodeId": "22222222-2222-2222-2222-222222222222",
          "stationId": "33333333-3333-3333-3333-333333333333",
          "airtime": "2025-02-15T15:00:00.000Z",
          "endTime": "2025-02-15T15:42:30.000Z",
          "createdAt": "2025-02-14T10:00:00.000Z",
          "updatedAt": "2025-02-14T10:00:00.000Z"
      }
      """
    let decoder = JSONDecoderWithIsoFull()
    let airing = try decoder.decode(Airing.self, from: json.data(using: .utf8)!)

    #expect(airing.startTime == nil)
    #expect(airing.endTime == DateFormatter.iso8601Full.date(from: "2025-02-15T15:42:30.000Z"))
  }

  @Test("Spin with a nested airing carrying the on-air window decodes end-to-end")
  func testSpinDecodesNestedAiringOnAirWindow() throws {
    let endTime = DateFormatter.iso8601Full.date(from: "2025-02-15T15:42:30.000Z")!
    let startTime = DateFormatter.iso8601Full.date(from: "2025-02-15T15:00:12.000Z")!

    let airing = Airing(
      id: "11111111-1111-1111-1111-111111111111",
      episodeId: "22222222-2222-2222-2222-222222222222",
      stationId: "33333333-3333-3333-3333-333333333333",
      airtime: DateFormatter.iso8601Full.date(from: "2025-02-15T15:00:00.000Z")!,
      createdAt: DateFormatter.iso8601Full.date(from: "2025-02-14T10:00:00.000Z")!,
      updatedAt: DateFormatter.iso8601Full.date(from: "2025-02-14T10:00:00.000Z")!,
      startTime: startTime,
      endTime: endTime)

    let spin = Spin.mockWith(airing: airing)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(.iso8601Full)
    let data = try encoder.encode(spin)

    let decoder = JSONDecoderWithIsoFull()
    let decoded = try decoder.decode(Spin.self, from: data)

    #expect(decoded.airing?.startTime == startTime)
    #expect(decoded.airing?.endTime == endTime)
  }
}
