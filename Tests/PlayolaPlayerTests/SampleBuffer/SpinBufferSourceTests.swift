//  SpinBufferSourceTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane B integration (T10 decode-at-offset, T11 format
//  normalization). Uses a self-contained temp-WAV fixture (no bundled binary):
//  a known stereo tone written at a chosen sample rate, decoded back through
//  SpinBufferSource (AVAudioFile -> AVAudioConverter -> fixed MixFormat).

import AVFoundation
import Foundation
import Testing

@testable import PlayolaPlayer

struct SpinBufferSourceTests {
  /// Writes a `seconds`-long stereo 440 Hz tone at `sampleRate` to a temp .wav and returns its URL.
  private func makeToneFile(sampleRate: Double, seconds: Double) throws -> URL {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".wav")
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frameCount = AVAudioFrameCount((sampleRate * seconds).rounded())
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let left = buffer.floatChannelData![0]
    let right = buffer.floatChannelData![1]
    for i in 0..<Int(frameCount) {
      let v = Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate)) * 0.5
      left[i] = v
      right[i] = v
    }
    try file.write(from: buffer)
    return url
  }

  private func toneSpin() -> Spin {
    Spin.mockWith(startingVolume: 1.0, fades: [])
  }

  @Test("decodes a same-rate file to the expected mix-frame count")
  func decodesFullFile() throws {
    let url = try makeToneFile(sampleRate: MixFormat.sampleRate, seconds: 1.0)
    let source = try SpinBufferSource(spin: toneSpin(), fileURL: url, startFrame: 0)

    try source.decode(throughSourceOffset: Int64(MixFormat.sampleRate * 2))  // over-request past EOF

    #expect(source.isFullyDecoded)
    // 1.0s at 48k == 48000 frames (same rate: no resample tolerance needed).
    #expect(source.decodedThroughOffset == 48_000)
    #expect(source.stereoFrame(atSourceOffset: 0) != nil)
    #expect(source.stereoFrame(atSourceOffset: 47_999) != nil)
    #expect(source.stereoFrame(atSourceOffset: 48_000) == nil)  // past end -> silence
  }

  @Test("mid-file join seeks the file and reads from the join offset")
  func midFileJoinReadsFromOffset() throws {
    let url = try makeToneFile(sampleRate: MixFormat.sampleRate, seconds: 1.0)
    let joinOffset: Int64 = 24_000  // 0.5s in
    let source = try SpinBufferSource(
      spin: toneSpin(), fileURL: url, startFrame: -joinOffset, initialSourceOffset: joinOffset)

    try source.decode(throughSourceOffset: joinOffset + 128)

    // Frames before the join offset were never decoded (we seeked past them).
    #expect(source.stereoFrame(atSourceOffset: 0) == nil)
    let joined = source.stereoFrame(atSourceOffset: joinOffset)
    #expect(joined != nil)
    // Same-rate: value equals the source tone at file frame 24000.
    let expected = Float(sin(2 * Double.pi * 440 * Double(joinOffset) / MixFormat.sampleRate)) * 0.5
    #expect(abs((joined?.x ?? -9) - expected) < 0.02)
  }

  @Test("a join offset past end-of-file yields silence, not a replay from frame 0")
  func joinPastEndOfFileIsSilent() throws {
    let url = try makeToneFile(sampleRate: MixFormat.sampleRate, seconds: 1.0)  // 48000 frames
    let joinOffset: Int64 = 60_000  // past the 48000-frame end
    let source = try SpinBufferSource(
      spin: toneSpin(), fileURL: url, startFrame: -joinOffset, initialSourceOffset: joinOffset)

    try source.decode(throughSourceOffset: joinOffset + 4_096)

    #expect(source.isFullyDecoded)
    // Must NOT replay the file's beginning at the past offset.
    #expect(source.stereoFrame(atSourceOffset: joinOffset) == nil)
    #expect(source.stereoFrame(atSourceOffset: 0) == nil)
  }

  @Test("resamples 44.1kHz and 48kHz sources to the same aligned mix length")
  func formatNormalization() throws {
    let url44 = try makeToneFile(sampleRate: 44_100, seconds: 0.5)
    let url48 = try makeToneFile(sampleRate: 48_000, seconds: 0.5)
    let source44 = try SpinBufferSource(spin: toneSpin(), fileURL: url44, startFrame: 0)
    let source48 = try SpinBufferSource(spin: toneSpin(), fileURL: url48, startFrame: 0)

    try source44.decode(throughSourceOffset: 100_000)
    try source48.decode(throughSourceOffset: 100_000)

    // 0.5s at the 48k mix rate == 24000 frames. The resampled 44.1k source lands
    // within a few frames of that (resampler edge), and the 48k source is exact.
    #expect(abs(source44.decodedThroughOffset - 24_000) <= 64)
    #expect(source48.decodedThroughOffset == 24_000)
  }

  @Test("snapshot captures the decoded window and is isolated from further decode")
  func snapshotIsImmutableAndIsolated() throws {
    let url = try makeToneFile(sampleRate: MixFormat.sampleRate, seconds: 1.0)
    let source = try SpinBufferSource(spin: toneSpin(), fileURL: url, startFrame: 0)

    try source.decode(throughSourceOffset: 10_000)
    let snap = source.snapshot()

    // Snapshot matches the source at capture time.
    #expect(snap.startFrame == source.startFrame)
    #expect(snap.stereoFrame(atSourceOffset: 5_000) == source.stereoFrame(atSourceOffset: 5_000))
    #expect(snap.stereoFrame(atSourceOffset: 9_999) != nil)
    #expect(snap.stereoFrame(atSourceOffset: 10_000) == nil)

    // Decoding further does not mutate the earlier snapshot (value semantics).
    try source.decode(throughSourceOffset: 20_000)
    #expect(snap.stereoFrame(atSourceOffset: 15_000) == nil)  // snapshot unchanged
    #expect(source.stereoFrame(atSourceOffset: 15_000) != nil)  // source advanced
  }

  @Test("discard drops whole leading chunks to bound memory, keeping later reads")
  func discardBoundsMemory() throws {
    let url = try makeToneFile(sampleRate: MixFormat.sampleRate, seconds: 1.0)
    let source = try SpinBufferSource(spin: toneSpin(), fileURL: url, startFrame: 0)

    // Decode in steps so the window holds several chunks (~4000 frames each).
    try source.decode(throughSourceOffset: 4_000)
    try source.decode(throughSourceOffset: 8_000)
    try source.decode(throughSourceOffset: 12_000)
    let before = source.stereoFrame(atSourceOffset: 9_000)

    source.discard(beforeSourceOffset: 5_000)  // drops the whole [0,4000) chunk (ends at/before 5000)

    #expect(source.stereoFrame(atSourceOffset: 3_000) == nil)  // in the dropped chunk
    #expect(source.stereoFrame(atSourceOffset: 9_000) == before)  // still readable
  }
}
