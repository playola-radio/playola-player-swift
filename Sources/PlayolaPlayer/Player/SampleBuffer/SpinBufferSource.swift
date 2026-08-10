import AVFoundation
import Foundation
import PlayolaCore

/// Owns per-file decode state for one spin on the sample-buffer render path.
///
/// Reads the downloaded audio file with `AVAudioFile` (which decodes compressed formats to PCM),
/// resamples to the fixed `MixFormat` with `AVAudioConverter`, and keeps a **bounded, forward-sliding
/// window** of already-decoded mix frames. The render-callback mixer reads that window through the
/// `MixSource` conformance and must NEVER trigger decode/IO here (eng-review A2): `stereoFrame` is pure
/// array access, and `nil` (not-yet-decoded / past end) renders as silence rather than blocking.
///
/// Decode is **forward-streaming after a single initial seek**: mid-file join seeks the file once to the
/// join offset, then a single converter instance produces frames sequentially (continuous resampler
/// state). The renderer drives `decode(throughSourceOffset:)` ahead of the render position on a
/// non-render executor and `discard(beforeSourceOffset:)` behind it to bound memory (P1 jetsam).
///
/// Not `Sendable`: `AVAudioFile`/`AVAudioConverter` are single-threaded; the owner serializes access.
final class SpinBufferSource: MixSource {
  /// Read-ahead / memory bound, in mix frames (~2 s). Named per eng-review P1; tuned on device (C10).
  static let readAheadFrames = Int(MixFormat.sampleRate * 2.0)

  let startFrame: Int64
  let envelope: FadeEnvelope
  let spinID: String

  private let audioFile: AVAudioFile
  private let converter: AVAudioConverter
  private let mixFormat: AVAudioFormat
  /// file-native frames per one mix frame (fileRate / mixRate).
  private let nativeFramesPerMixFrame: Double

  /// Decoded window covers source offsets [windowStart, windowStart + frames.count).
  private var windowStart: Int64
  private var frames: [SIMD2<Float>] = []
  private var reachedEndOfFile = false

  /// - Parameters:
  ///   - spin: source of fade truth (envelope) and identity.
  ///   - fileURL: the downloaded, complete local audio file.
  ///   - startFrame: mix-timeline frame at which the spin's frame 0 is presented (may be negative).
  ///   - initialSourceOffset: mix-frame offset into the file to begin decoding from (mid-file join);
  ///     0 for a spin played from its start.
  init(spin: Spin, fileURL: URL, startFrame: Int64, initialSourceOffset: Int64 = 0) throws {
    self.spinID = spin.id
    self.envelope = FadeEnvelope(spin: spin)
    self.startFrame = startFrame

    let file = try AVAudioFile(forReading: fileURL)
    self.audioFile = file
    let mix = MixFormat.avAudioFormat()
    self.mixFormat = mix
    self.nativeFramesPerMixFrame = file.processingFormat.sampleRate / mix.sampleRate

    guard let converter = AVAudioConverter(from: file.processingFormat, to: mix) else {
      throw SpinBufferSourceError.converterUnavailable(
        from: file.processingFormat, to: mix)
    }
    self.converter = converter

    self.windowStart = max(0, initialSourceOffset)
    // Seek the file once to the join offset; decoding proceeds forward from here.
    let nativeStart = AVAudioFramePosition(Double(self.windowStart) * nativeFramesPerMixFrame)
    if nativeStart >= file.length {
      // Join offset is at/after end-of-file (spin already over): decode nothing, produce silence.
      // Without this the un-seeked file stays at frame 0 and would replay the start from a past offset.
      reachedEndOfFile = true
    } else if nativeStart > 0 {
      file.framePosition = nativeStart
    }
  }

  // MARK: - MixSource (render thread — decode/IO-free)

  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>? {
    guard offset >= windowStart else { return nil }
    let index = Int(offset - windowStart)
    guard index < frames.count else { return nil }
    return frames[index]
  }

  /// A cheap immutable snapshot of the currently-decoded window, for the render side.
  ///
  /// The decode queue owns and mutates a `SpinBufferSource`; the render callback must never touch it
  /// (it isn't `Sendable` and its `frames` are mutated on the decode queue). Instead the decode driver
  /// publishes a `SpinPCMWindow` — a `Sendable` `MixSource` the renderer installs on its own serial
  /// queue (PHASE_5_PLAN §4 / Codex design 019feda9). `frames` shares storage via copy-on-write until
  /// the next decode append, so snapshotting is O(1) in the common case.
  func snapshot() -> SpinPCMWindow {
    SpinPCMWindow(
      spinID: spinID, startFrame: startFrame, envelope: envelope,
      windowStart: windowStart, frames: frames)
  }

  // MARK: - Decode driver (non-render executor)

  /// Highest source offset currently decoded and readable (exclusive upper bound).
  var decodedThroughOffset: Int64 { windowStart + Int64(frames.count) }

  /// True once the whole file has been decoded into (or past) the window.
  var isFullyDecoded: Bool { reachedEndOfFile }

  /// Decode forward until the window covers up to (but not including) `target`, or EOF. Safe to
  /// over-request; no-ops once `target` is already decoded or the file is exhausted. Off the render thread.
  @discardableResult
  func decode(throughSourceOffset target: Int64) throws -> Int {
    var produced = 0
    while !reachedEndOfFile && decodedThroughOffset < target {
      let remaining = target - decodedThroughOffset
      let chunk = min(Int(remaining), Self.readAheadFrames)
      produced += try decodeChunk(maxFrames: chunk)
    }
    return produced
  }

  /// Drop decoded frames strictly before `offset` to bound memory. The renderer calls this with a value
  /// at/behind the current render position; never drops frames the renderer may still read.
  func discard(beforeSourceOffset offset: Int64) {
    guard offset > windowStart else { return }
    let dropCount = min(Int(offset - windowStart), frames.count)
    guard dropCount > 0 else { return }
    frames.removeFirst(dropCount)
    windowStart += Int64(dropCount)
  }

  // MARK: - Private

  private func decodeChunk(maxFrames: Int) throws -> Int {
    let capacity = AVAudioFrameCount(max(1, maxFrames))
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: capacity) else {
      throw SpinBufferSourceError.bufferAllocationFailed
    }

    let inputFormat = audioFile.processingFormat
    var readError: Error?
    let status = converter.convert(to: outBuffer, error: nil) {
      [audioFile] inNumPackets, outStatus in
      // At/after end-of-file, reading throws on macOS — report EOS without reading.
      guard audioFile.framePosition < audioFile.length else {
        outStatus.pointee = .endOfStream
        return nil
      }
      guard inNumPackets > 0,
        let inBuffer = AVAudioPCMBuffer(
          pcmFormat: inputFormat, frameCapacity: inNumPackets)
      else {
        outStatus.pointee = .endOfStream
        return nil
      }
      do {
        try audioFile.read(into: inBuffer, frameCount: inNumPackets)
      } catch {
        readError = error
        outStatus.pointee = .endOfStream
        return nil
      }
      if inBuffer.frameLength == 0 {
        outStatus.pointee = .endOfStream
        return nil
      }
      outStatus.pointee = .haveData
      return inBuffer
    }

    if let readError { throw readError }

    let outFrames = Int(outBuffer.frameLength)
    if outFrames > 0, let channels = outBuffer.floatChannelData {
      let left = channels[0]
      let right = mixFormat.channelCount > 1 ? channels[1] : channels[0]
      frames.reserveCapacity(frames.count + outFrames)
      for i in 0..<outFrames {
        frames.append(SIMD2(left[i], right[i]))
      }
    }

    if status == .endOfStream || status == .error || outFrames == 0 {
      reachedEndOfFile = true
    }
    return outFrames
  }
}

/// Immutable, `Sendable` snapshot of a `SpinBufferSource`'s decoded window — the value the render
/// callback reads. Because it is a value type with immutable storage, it is safe to hand across the
/// decode → render queue boundary and to keep as long as the renderer needs it.
struct SpinPCMWindow: MixSource, Sendable {
  let spinID: String
  let startFrame: Int64
  let envelope: FadeEnvelope
  let windowStart: Int64
  let frames: [SIMD2<Float>]

  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>? {
    guard offset >= windowStart else { return nil }
    let index = Int(offset - windowStart)
    guard index < frames.count else { return nil }
    return frames[index]
  }
}

enum SpinBufferSourceError: Error, CustomStringConvertible {
  case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)
  case bufferAllocationFailed

  var description: String {
    switch self {
    case .converterUnavailable(let from, let to):
      return "AVAudioConverter unavailable from \(from) to \(to)"
    case .bufferAllocationFailed:
      return "Failed to allocate mix PCM buffer"
    }
  }
}
