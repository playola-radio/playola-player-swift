//  DriftReanchorTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane D (T8 / eng-review A1). Over a long session the synchronizer's
//  audio/AirPlay timebase drifts from Date() wall clock. Re-anchoring the
//  timeline at each spin boundary keeps every spin's authored frame aligned to
//  fresh wall clock (error bounded by intra-spin drift), whereas a single
//  never-corrected anchor lets the error grow without bound.

import Foundation
import Testing

@testable import PlayolaPlayer

struct DriftReanchorTests {
  private let anchor = Date(timeIntervalSince1970: 1_700_000_000)
  private let sampleRate: Double = 48_000
  private let spinSeconds: Double = 180
  private let driftRate = 0.0001  // audio clock runs ~100 ppm fast
  private let spinCount = 20

  /// The synchronizer playhead (station frame) after `elapsed` real wall-clock seconds, given the
  /// audio clock advances slightly faster than wall clock.
  private func playheadFrame(elapsed: Double) -> Int64 {
    Int64(elapsed * (1 + driftRate) * sampleRate)
  }

  @Test("boundary re-anchor keeps per-spin PTS aligned to wall clock; a fixed anchor drifts")
  func reanchorBoundsDrift() {
    let toleranceSeconds = spinSeconds * driftRate * 1.5  // ~one spin of intra-spin drift
    var reanchored = TimelineMapper(anchorDate: anchor, scheduleOffset: 0, sampleRate: sampleRate)
    let fixed = TimelineMapper(anchorDate: anchor, scheduleOffset: 0, sampleRate: sampleRate)

    var worstReanchoredError = 0.0
    var worstFixedError = 0.0

    for k in 0..<spinCount {
      let elapsed = Double(k) * spinSeconds
      let now = anchor.addingTimeInterval(elapsed)
      let playhead = playheadFrame(elapsed: elapsed)

      // Error = how far each mapper's authored frame for "the spin airing now" is from the actual
      // playhead, expressed in seconds.
      let reErr = abs(Double(reanchored.frame(for: now) - playhead)) / sampleRate
      let fixErr = abs(Double(fixed.frame(for: now) - playhead)) / sampleRate
      worstReanchoredError = max(worstReanchoredError, reErr)
      worstFixedError = max(worstFixedError, fixErr)

      // Re-anchor at the boundary from fresh wall clock + the real playhead.
      reanchored = reanchored.reanchored(now: now, currentStationFrame: playhead)
    }

    #expect(worstReanchoredError < toleranceSeconds)
    // The fixed anchor accumulates well beyond the per-spin tolerance by session end.
    #expect(worstFixedError > toleranceSeconds * 5)
  }

  @Test("reanchored pins the current frame exactly")
  func reanchorPinsCurrentFrame() {
    let mapper = TimelineMapper(anchorDate: anchor, scheduleOffset: 0, sampleRate: sampleRate)
    let now = anchor.addingTimeInterval(1_000)
    let playhead: Int64 = 48_000_123
    let pinned = mapper.reanchored(now: now, currentStationFrame: playhead)
    #expect(abs(pinned.frame(for: now) - playhead) <= 1)
  }
}
