import AVFoundation

/// The single fixed output format of the sample-buffer render path: **stereo float32 PCM** at one
/// chosen sample rate. Every `SpinBufferSource` resamples its file to this format during decode, so the
/// mixer only ever sums like-for-like frames (PHASE_5_PLAN §4.3).
///
/// A frame is one `SIMD2<Float>` (L, R). An array of frames is, in memory, exactly interleaved
/// L,R,L,R… float32 — the layout `AVSampleBufferAudioRenderer`'s `CMSampleBuffer` wants — so the sink
/// adapter can copy the mixer's output straight into a `CMBlockBuffer` with no interleave conversion.
enum MixFormat {
  /// 48 kHz — AirPlay-2's native long-form rate; avoids an extra resample on the output device.
  static let sampleRate: Double = 48_000
  static let channelCount: AVAudioChannelCount = 2

  /// Non-interleaved float32 stereo at the mix rate — the working format for `AVAudioConverter` output.
  /// (Non-interleaved so per-channel samples are read via `floatChannelData`; the ring stores them as
  /// interleaved `SIMD2<Float>` pairs, which is what CoreMedia ultimately consumes.)
  static func avAudioFormat() -> AVAudioFormat {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: channelCount,
      interleaved: false)!
  }
}
