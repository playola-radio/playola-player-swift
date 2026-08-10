//  RenderPathNoDecodeIOTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane D (T9 / eng-review A2). The render-callback mix path must
//  perform ZERO decode / file IO: it only reads already-decoded PCM. This spy
//  source flags if its decode entry point is ever touched from the mix path and
//  asserts the mixer only ever calls the pure `stereoFrame` accessor.

import Foundation
import Testing

@testable import PlayolaPlayer

private final class DecodeSpySource: MixSource, @unchecked Sendable {
  let startFrame: Int64 = 0
  let envelope: FadeEnvelope
  private(set) var stereoFrameCalls = 0
  private(set) var decodeWasCalled = false

  init() {
    envelope = FadeEnvelope(spin: Spin.mockWith(startingVolume: 1.0, fades: []))
  }

  /// A decode/IO entry point analogous to `SpinBufferSource.decode` — the mixer must NEVER call it.
  func decode(throughSourceOffset target: Int64) {
    decodeWasCalled = true
  }

  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>? {
    stereoFrameCalls += 1
    return SIMD2(0.1, 0.1)
  }
}

struct RenderPathNoDecodeIOTests {
  @Test("the mixer render path never triggers decode/IO — only ready-PCM reads")
  func mixerIsDecodeIOFree() {
    let spy = DecodeSpySource()
    let mixer = TimelineMixer(sampleRate: 48_000)
    var out = [Float](repeating: 0, count: 512 * 2)

    mixer.render(outputFrameRange: 0..<512, sources: [spy], into: &out)

    #expect(spy.decodeWasCalled == false)  // no decode from the render/mix path
    #expect(spy.stereoFrameCalls == 512)  // only ready-PCM reads, one per frame
  }
}
