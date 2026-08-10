//  TimelineMixerTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane A CENTERPIECE (T2, T4). The pure, real-time-safe mixer:
//  (active sources, output frame range) -> interleaved stereo float32 PCM.
//  Sums overlapping sources with per-spin fade gain, clip-protects the sum, and
//  fills silence for any source frame that is not ready (never stalls). No
//  CoreMedia, no decode, no IO here — this is audio truth, unit-tested.

import Foundation
import Testing

@testable import PlayolaPlayer

private struct ArrayMixSource: MixSource {
  let startFrame: Int64
  let envelope: FadeEnvelope
  let frames: [SIMD2<Float>]

  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>? {
    guard offset >= 0, offset < Int64(frames.count) else { return nil }
    return frames[Int(offset)]
  }
}

@MainActor
struct TimelineMixerTests {
  private let sampleRate: Double = 48_000

  private func unityEnvelope(_ volume: Float = 1.0) -> FadeEnvelope {
    FadeEnvelope(spin: Spin.mockWith(startingVolume: volume, fades: []))
  }

  private func constantSource(
    start: Int64, value: SIMD2<Float>, length: Int, volume: Float = 1.0
  ) -> ArrayMixSource {
    ArrayMixSource(
      startFrame: start,
      envelope: unityEnvelope(volume),
      frames: Array(repeating: value, count: length))
  }

  /// Reads interleaved output frame `f` (0-based within the rendered range) as (L, R).
  private func frame(_ out: [Float], _ f: Int) -> SIMD2<Float> {
    SIMD2(out[f * 2], out[f * 2 + 1])
  }

  @Test("two overlapping sources sum sample-for-sample")
  func overlappingSourcesSum() {
    let mixer = TimelineMixer(sampleRate: sampleRate)
    let a = constantSource(start: 0, value: SIMD2(0.5, 0.5), length: 4)
    let b = constantSource(start: 0, value: SIMD2(0.2, -0.1), length: 4)
    var out = [Float](repeating: .nan, count: 4 * 2)

    mixer.render(outputFrameRange: 0..<4, sources: [a, b], into: &out)

    for f in 0..<4 {
      #expect(abs(frame(out, f).x - 0.7) < 0.0001)
      #expect(abs(frame(out, f).y - 0.4) < 0.0001)
    }
  }

  @Test("per-spin ducking gain scales that source's contribution")
  func duckingGainApplied() {
    let mixer = TimelineMixer(sampleRate: sampleRate)
    // Bed at unity + voicetrack held at 0.5 startingVolume.
    let bed = constantSource(start: 0, value: SIMD2(0.4, 0.4), length: 4, volume: 1.0)
    let voice = constantSource(start: 0, value: SIMD2(0.8, 0.8), length: 4, volume: 0.5)
    var out = [Float](repeating: 0, count: 4 * 2)

    mixer.render(outputFrameRange: 0..<4, sources: [bed, voice], into: &out)

    // 0.4 (bed) + 0.8 * 0.5 (ducked voice) = 0.8
    #expect(abs(frame(out, 0).x - 0.8) < 0.0001)
  }

  @Test("a missing/not-ready source contributes silence and does not stall")
  func missingSourceIsSilent() {
    let mixer = TimelineMixer(sampleRate: sampleRate)
    let ready = constantSource(start: 0, value: SIMD2(0.3, 0.3), length: 4)
    let notReady = ArrayMixSource(startFrame: 0, envelope: unityEnvelope(), frames: [])
    var out = [Float](repeating: .nan, count: 4 * 2)

    mixer.render(outputFrameRange: 0..<4, sources: [ready, notReady], into: &out)

    // Only the ready source is heard; the empty source adds nothing.
    for f in 0..<4 {
      #expect(abs(frame(out, f).x - 0.3) < 0.0001)
    }
  }

  @Test("partial availability fills the un-decoded tail with silence")
  func partialAvailabilityTailSilent() {
    let mixer = TimelineMixer(sampleRate: sampleRate)
    // Only the first 2 of 4 output frames are decoded.
    let partial = constantSource(start: 0, value: SIMD2(0.6, 0.6), length: 2)
    var out = [Float](repeating: 7, count: 4 * 2)

    mixer.render(outputFrameRange: 0..<4, sources: [partial], into: &out)

    #expect(abs(frame(out, 1).x - 0.6) < 0.0001)
    #expect(frame(out, 2).x == 0.0)  // silence, not stale 7s
    #expect(frame(out, 3).x == 0.0)
  }

  @Test("negative start frame reads from the mid-file join offset")
  func negativeStartFrameJoinsMidFile() {
    let mixer = TimelineMixer(sampleRate: sampleRate)
    // Source began 2 frames before the anchor: output frame 0 should read source frame 2.
    let frames = (0..<6).map { SIMD2<Float>(Float($0) / 10, Float($0) / 10) }
    let joined = ArrayMixSource(startFrame: -2, envelope: unityEnvelope(), frames: frames)
    var out = [Float](repeating: 0, count: 3 * 2)

    mixer.render(outputFrameRange: 0..<3, sources: [joined], into: &out)

    #expect(abs(frame(out, 0).x - 0.2) < 0.0001)  // source frame 2
    #expect(abs(frame(out, 1).x - 0.3) < 0.0001)  // source frame 3
    #expect(abs(frame(out, 2).x - 0.4) < 0.0001)  // source frame 4
  }

  @Test("a source that starts mid-range is silent before its start frame")
  func futureStartFrameSilentUntilStart() {
    let mixer = TimelineMixer(sampleRate: sampleRate)
    let src = constantSource(start: 2, value: SIMD2(0.5, 0.5), length: 4)
    var out = [Float](repeating: 9, count: 4 * 2)

    mixer.render(outputFrameRange: 0..<4, sources: [src], into: &out)

    #expect(frame(out, 0).x == 0.0)  // before startFrame -> silence
    #expect(frame(out, 1).x == 0.0)
    #expect(abs(frame(out, 2).x - 0.5) < 0.0001)
    #expect(abs(frame(out, 3).x - 0.5) < 0.0001)
  }

  @Test("summed peaks are clip-protected to [-1, 1]")
  func clipProtection() {
    let mixer = TimelineMixer(sampleRate: sampleRate)
    let a = constantSource(start: 0, value: SIMD2(0.8, -0.8), length: 2)
    let b = constantSource(start: 0, value: SIMD2(0.8, -0.8), length: 2)
    var out = [Float](repeating: 0, count: 2 * 2)

    mixer.render(outputFrameRange: 0..<2, sources: [a, b], into: &out)

    #expect(frame(out, 0).x == 1.0)  // 1.6 clipped
    #expect(frame(out, 0).y == -1.0)  // -1.6 clipped
  }

  @Test("no sources yields pure silence")
  func noSourcesSilent() {
    let mixer = TimelineMixer(sampleRate: sampleRate)
    var out = [Float](repeating: 5, count: 3 * 2)
    mixer.render(outputFrameRange: 10..<13, sources: [], into: &out)
    #expect(out.allSatisfy { $0 == 0.0 })
  }
}
