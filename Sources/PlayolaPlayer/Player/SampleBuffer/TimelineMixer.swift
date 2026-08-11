import Foundation

/// A source of already-decoded, mix-format (interleaved stereo float32) PCM for one spin, addressed by
/// frame offset from the spin's own start.
///
/// **Real-time contract [PHASE_5_PLAN §4 / eng-review A2]:** `stereoFrame(atSourceOffset:)` must be
/// decode/IO-free — it only returns PCM that some other executor has already decoded into a bounded
/// ring buffer. A frame that is not (yet) available returns `nil`, which the mixer renders as silence;
/// it must never block waiting for a decode or download.
protocol MixSource: Sendable {
  /// Output frame (on the mix timeline) at which this source's frame 0 is presented. Negative when the
  /// spin began before the station-timeline anchor (mid-file join reads from the positive offset).
  var startFrame: Int64 { get }

  /// Per-position playback gain for this spin (ducking/fades), derived from `Spin.volumeAt*`.
  var envelope: FadeEnvelope { get }

  /// The already-decoded interleaved-stereo frame at `offset` frames into the spin, or `nil` if that
  /// frame is not currently available (not decoded, out of range, or past end-of-file). Decode/IO-free.
  ///
  /// The render callback only ever reads immutable `SpinPCMWindow` snapshots through this. Memory is
  /// bounded on the DECODE side (`SpinBufferSource.discard` before it publishes a trimmed snapshot),
  /// not by the render path — so there is no in-place trim on the mix source.
  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>?
}

/// Pure software mixer for the sample-buffer render path (Phase 5 centerpiece).
///
/// For an output frame range on the mix timeline it finds every source whose window intersects the
/// range, reads each source's already-decoded PCM at the matching offset, applies that spin's per-frame
/// fade gain, sums the overlapping contributions, and clip-protects the result — emitting one block of
/// interleaved stereo float32 PCM. A source frame that is not ready contributes silence, so one slow
/// download can never stall the mix. Never decodes or touches IO.
struct TimelineMixer: Sendable {
  /// Mixed-output sample rate (frames per second). All sources are resampled to this during decode.
  let sampleRate: Double

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
  }

  /// Render into `output`, an interleaved stereo float32 buffer that MUST have
  /// `outputFrameRange.count * 2` elements. `output` is fully overwritten (zeroed first).
  func render(outputFrameRange: Range<Int64>, sources: [MixSource], into output: inout [Float]) {
    precondition(
      output.count == Int(outputFrameRange.count) * 2,
      "output buffer must hold outputFrameRange.count * 2 samples")
    output.withUnsafeMutableBufferPointer { renderCore(outputFrameRange, sources, into: $0) }
  }

  /// Render straight into a reusable `[SIMD2<Float>]` frame buffer (its memory is interleaved L,R… — the
  /// exact CMSampleBuffer layout), so the render path avoids a per-buffer scratch alloc + float→SIMD2
  /// conversion pass. MUST have `outputFrameRange.count` elements.
  func render(
    outputFrameRange: Range<Int64>, sources: [MixSource], intoFrames frames: inout [SIMD2<Float>]
  ) {
    precondition(
      frames.count == Int(outputFrameRange.count),
      "frame buffer must hold outputFrameRange.count frames")
    frames.withUnsafeMutableBytes { raw in
      renderCore(outputFrameRange, sources, into: raw.bindMemory(to: Float.self))
    }
  }

  private func renderCore(
    _ range: Range<Int64>, _ sources: [MixSource], into out: UnsafeMutableBufferPointer<Float>
  ) {
    let sampleCount = Int(range.count) * 2
    for i in 0..<sampleCount { out[i] = 0 }

    let lower = range.lowerBound
    let upper = range.upperBound
    for source in sources {
      // Hoist protocol/property access out of the per-sample loop (each was a witness call per frame).
      let sourceStart = source.startFrame
      let envelope = source.envelope
      var f = max(lower, sourceStart)  // skip frames before this source starts (offset would be negative)
      while f < upper {
        let offset = f - sourceStart  // >= 0, position within the spin
        if let sample = source.stereoFrame(atSourceOffset: offset) {
          let gain = envelope.gain(atFrame: offset, sampleRate: sampleRate)
          let outIndex = Int(f - lower) * 2
          out[outIndex] += sample.x * gain
          out[outIndex + 1] += sample.y * gain
        }
        f += 1
      }
    }

    // Clip-protection on the summed program (no limiter/mastering in slice 1).
    for i in 0..<sampleCount { out[i] = min(1.0, max(-1.0, out[i])) }
  }
}
