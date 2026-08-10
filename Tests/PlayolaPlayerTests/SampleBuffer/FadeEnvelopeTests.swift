//  FadeEnvelopeTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane A (T3). FadeEnvelope reproduces the legacy render path's
//  ~1.5s linear volume ramps, with fade targets + startingVolume derived from
//  the SAME Spin fade truth the legacy AU automation uses (Spin.volumeAt*).
//  Parity is asserted at plateau offsets (where the ramped envelope and the
//  stepwise Spin.volumeAtMS agree); the ramp itself is linear between them.

import Foundation
import Testing

@testable import PlayolaPlayer

struct FadeEnvelopeTests {
  // Duck down to 0.2 at 5s, back up to 1.0 at 10s — the canonical voicetrack duck.
  private func duckSpin() -> Spin {
    Spin.mockWith(
      startingVolume: 1.0,
      fades: [Fade(atMS: 5_000, toVolume: 0.2), Fade(atMS: 10_000, toVolume: 1.0)]
    )
  }

  @Test("holds starting volume before the first fade")
  func baselineHold() {
    let env = FadeEnvelope(spin: duckSpin())
    #expect(env.gain(atMS: 0) == 1.0)
    #expect(env.gain(atMS: 4_999) == 1.0)
  }

  @Test("ramps linearly over 1.5s from the previous level to the fade target")
  func linearRampDown() {
    let env = FadeEnvelope(spin: duckSpin())
    #expect(env.gain(atMS: 5_000) == 1.0)  // ramp starts at the previous level
    #expect(abs(env.gain(atMS: 5_750) - 0.6) < 0.0001)  // halfway: 1.0 + 0.5*(0.2-1.0)
    #expect(abs(env.gain(atMS: 6_500) - 0.2) < 0.0001)  // ramp complete
  }

  @Test("holds the fade target, then ramps back up")
  func holdThenRampUp() {
    let env = FadeEnvelope(spin: duckSpin())
    #expect(abs(env.gain(atMS: 9_000) - 0.2) < 0.0001)  // plateau
    #expect(abs(env.gain(atMS: 10_750) - 0.6) < 0.0001)  // halfway 0.2 -> 1.0
    #expect(abs(env.gain(atMS: 11_500) - 1.0) < 0.0001)  // complete
  }

  @Test("seconds and frame accessors agree with the millisecond accessor")
  func accessorsAgree() {
    let env = FadeEnvelope(spin: duckSpin())
    #expect(abs(env.gain(atSeconds: 5.75) - env.gain(atMS: 5_750)) < 0.0001)
    #expect(abs(env.gain(atFrame: 276_000, sampleRate: 48_000) - env.gain(atMS: 5_750)) < 0.0001)
  }

  @Test("equals Spin.volumeAtMS at plateau offsets (single-source parity)")
  func plateauParityWithSpin() {
    let spin = duckSpin()
    let env = FadeEnvelope(spin: spin)
    // Plateaus: before the fade, after each ramp completes. There the ramped
    // envelope and the stepwise legacy Spin.volumeAtMS agree exactly.
    for ms in [0, 4_000, 6_500, 9_000, 11_500, 20_000] {
      #expect(env.gain(atMS: ms) == spin.volumeAtMS(ms))
    }
  }

  @Test("no fades holds startingVolume everywhere")
  func noFades() {
    let env = FadeEnvelope(spin: Spin.mockWith(startingVolume: 0.75, fades: []))
    #expect(env.gain(atMS: 0) == 0.75)
    #expect(env.gain(atMS: 60_000) == 0.75)
  }
}
