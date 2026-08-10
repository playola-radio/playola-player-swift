import Foundation

/// A source of already-decoded, mix-format (interleaved stereo float32) PCM for one spin, addressed by
/// frame offset from the spin's own start.
///
/// **Real-time contract [PHASE_5_PLAN §4 / eng-review A2]:** `stereoFrame(atSourceOffset:)` must be
/// decode/IO-free — it only returns PCM that some other executor has already decoded into a bounded
/// ring buffer. A frame that is not (yet) available returns `nil`, which the mixer renders as silence;
/// it must never block waiting for a decode or download.
protocol MixSource {
  /// Output frame (on the mix timeline) at which this source's frame 0 is presented. Negative when the
  /// spin began before the station-timeline anchor (mid-file join reads from the positive offset).
  var startFrame: Int64 { get }

  /// Per-position playback gain for this spin (ducking/fades), derived from `Spin.volumeAt*`.
  var envelope: FadeEnvelope { get }

  /// The already-decoded interleaved-stereo frame at `offset` frames into the spin, or `nil` if that
  /// frame is not currently available (not decoded, out of range, or past end-of-file). Decode/IO-free.
  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>?

  /// Release decoded frames strictly before `offset` (already-presented audio) to bound memory
  /// [eng-review P1]. The renderer calls this behind the playhead after each pull. Default: no-op (for
  /// in-memory test sources); `SpinBufferSource` overrides it to trim its ring buffer.
  func discard(beforeSourceOffset offset: Int64)
}

extension MixSource {
  func discard(beforeSourceOffset offset: Int64) {}
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

  /// Render `outputFrameRange` (mix-timeline frames) into `output`, an interleaved stereo float32 buffer
  /// that MUST have `outputFrameRange.count * 2` elements. `output` is fully overwritten (zeroed first).
  func render(outputFrameRange: Range<Int64>, sources: [MixSource], into output: inout [Float]) {
    let frameCount = Int(outputFrameRange.count)
    let sampleCount = frameCount * 2
    precondition(
      output.count == sampleCount,
      "output buffer must hold outputFrameRange.count * 2 samples")

    output.withUnsafeMutableBufferPointer { out in
      for i in 0..<sampleCount { out[i] = 0 }

      for source in sources {
        // Skip frames before this source starts (offset would be negative).
        let firstFrame = max(outputFrameRange.lowerBound, source.startFrame)
        var f = firstFrame
        while f < outputFrameRange.upperBound {
          let offset = f - source.startFrame  // >= 0, position within the spin
          if let sample = source.stereoFrame(atSourceOffset: offset) {
            let gain = source.envelope.gain(atFrame: offset, sampleRate: sampleRate)
            let outIndex = Int(f - outputFrameRange.lowerBound) * 2
            out[outIndex] += sample.x * gain
            out[outIndex + 1] += sample.y * gain
          }
          f += 1
        }
      }

      // Clip-protection on the summed program (no limiter/mastering in slice 1).
      for i in 0..<sampleCount {
        out[i] = min(1.0, max(-1.0, out[i]))
      }
    }
  }
}
