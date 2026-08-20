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

  /// Block read for the mixer's hot loop: invoke `body` once per maximal run of contiguous,
  /// already-decoded frames intersecting source offsets `range`, delivered in ascending order.
  /// `body(runStartOffset, ptr)` gets a pointer covering source offsets
  /// `[runStartOffset, runStartOffset + ptr.count)`. Undecoded / out-of-range gaps are skipped (the
  /// mixer renders them as silence), so this is exactly equivalent to reading each frame with
  /// `stereoFrame` — just coalesced. Decode/IO-free, same real-time contract as `stereoFrame`.
  ///
  /// This lets the mixer make ~one call per decoded chunk instead of one witness call + binary search
  /// per sample. The default implementation coalesces `stereoFrame` reads (correct for any source);
  /// `SpinPCMWindow` overrides it with a per-chunk copy — the production hot path.
  func withDecodedRuns(
    inSourceOffsets range: Range<Int64>,
    _ body: (Int64, UnsafeBufferPointer<SIMD2<Float>>) -> Void)
}

extension MixSource {
  /// Correct-for-any-source fallback: walk `range` once with `stereoFrame`, coalescing each contiguous
  /// available span into a single `body` call. Only the boundary frame that ends a run costs one extra
  /// `stereoFrame` call; a fully-available range calls it exactly once per frame. Allocates a scratch
  /// run buffer, so it is only for non-chunked sources (test doubles) — `SpinPCMWindow` overrides this.
  func withDecodedRuns(
    inSourceOffsets range: Range<Int64>,
    _ body: (Int64, UnsafeBufferPointer<SIMD2<Float>>) -> Void
  ) {
    var run: [SIMD2<Float>] = []
    var frame = range.lowerBound
    while frame < range.upperBound {
      run.removeAll(keepingCapacity: true)
      var cursor = frame
      while cursor < range.upperBound, let sample = stereoFrame(atSourceOffset: cursor) {
        run.append(sample)
        cursor += 1
      }
      if run.isEmpty {
        frame += 1  // frame not available — one stereoFrame(nil) probe, skip to the next
      } else {
        run.withUnsafeBufferPointer { body(frame, $0) }
        frame = cursor
      }
    }
  }
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
    let rate = sampleRate
    for source in sources {
      // Hoist protocol/property access out of the per-sample loop (each was a witness call per frame).
      let sourceStart = source.startFrame
      let envelope = source.envelope
      // Skip frames before this source starts (its offset would be negative there).
      let reqLower = max(lower, sourceStart)
      guard reqLower < upper else { continue }
      // Source offsets (>= 0) this output window needs; the block read hands back contiguous decoded runs.
      let offsetRange = (reqLower - sourceStart)..<(upper - sourceStart)
      source.withDecodedRuns(inSourceOffsets: offsetRange) { runStart, ptr in
        // Concrete per-run loop over a plain pointer: no per-sample witness call or binary search, and
        // gain over a `FadeEnvelope` value the optimizer can inline (PHASE_5 followup-15).
        let outFrameBase = Int(runStart + sourceStart - lower)
        for j in 0..<ptr.count {
          let gain = envelope.gain(atFrame: runStart + Int64(j), sampleRate: rate)
          let sample = ptr[j]
          let outIndex = (outFrameBase + j) * 2
          out[outIndex] += sample.x * gain
          out[outIndex + 1] += sample.y * gain
        }
      }
    }

    // Clip-protection on the summed program (no limiter/mastering in slice 1).
    for i in 0..<sampleCount { out[i] = min(1.0, max(-1.0, out[i])) }
  }
}
