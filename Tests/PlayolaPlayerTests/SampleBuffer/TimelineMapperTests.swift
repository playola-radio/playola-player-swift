//  TimelineMapperTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane A (T1). Locks the wall-clock <-> output-frame mapping the
//  sample-buffer mixer is authored on. Pure value type; no CoreMedia.

import Foundation
import Testing

@testable import PlayolaPlayer

struct TimelineMapperTests {
  private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("airtime maps to the expected output frame from a fixed anchor")
  func airtimeToFrame() {
    let mapper = TimelineMapper(anchorDate: anchor, scheduleOffset: 0, sampleRate: 48_000)
    // A spin airing 2s after the anchor begins at frame 2 * 48000.
    let airtime = anchor.addingTimeInterval(2.0)
    #expect(mapper.frame(for: airtime) == 96_000)
    // The anchor instant itself is frame 0.
    #expect(mapper.frame(for: anchor) == 0)
  }

  @Test("a spin already airing before the anchor has a negative start frame")
  func alreadyAiringIsNegative() {
    let mapper = TimelineMapper(anchorDate: anchor, scheduleOffset: 0, sampleRate: 48_000)
    let startedEarlier = anchor.addingTimeInterval(-1.5)
    #expect(mapper.frame(for: startedEarlier) == -72_000)
  }

  @Test("frame <-> date round-trips within one frame")
  func roundTrip() {
    let mapper = TimelineMapper(anchorDate: anchor, scheduleOffset: 0, sampleRate: 44_100)
    for frame: Int64 in [0, 1, 44_100, -44_100, 1_234_567, -987_654] {
      let date = mapper.date(forFrame: frame)
      #expect(mapper.frame(for: date) == frame)
    }
  }

  @Test("scheduleOffset shifts the whole timeline forward")
  func scheduleOffsetShift() {
    let live = TimelineMapper(anchorDate: anchor, scheduleOffset: 0, sampleRate: 48_000)
    // A +10s schedule offset means the same wall-clock instant lands 10s later
    // on the station timeline (10 * 48000 more frames).
    let shifted = TimelineMapper(anchorDate: anchor, scheduleOffset: 10, sampleRate: 48_000)
    let airtime = anchor.addingTimeInterval(2.0)
    #expect(shifted.frame(for: airtime) - live.frame(for: airtime) == 480_000)
  }
}
