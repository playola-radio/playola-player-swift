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
/// Not `Sendable` and NOT a `MixSource`: `AVAudioFile`/`AVAudioConverter` are single-threaded and stay
/// on the decode queue. The render side reads its `snapshot()` (an immutable `SpinPCMWindow`), never the
/// source itself — so the queue-crossing `MixSource` contract only ever carries `Sendable` values.
final class SpinBufferSource {
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

  /// Decoded PCM stored as a list of IMMUTABLE chunks (one per decode output). Appending a new chunk
  /// never copies the existing ones, and a `snapshot()` just shares the chunk list by reference — so
  /// publishing a snapshot every decode pass is O(chunks), not a ~MB deep copy of the whole window
  /// (that copy was ~20MB/s across active sources and drove energy up — C11). Covers source offsets
  /// [windowStart, windowStart + totalFrames).
  private var windowStart: Int64
  private var chunks: [[SIMD2<Float>]] = []
  private var totalFrames = 0
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

  // MARK: - Reads (decode/IO-free)

  /// Frame lookup for tests; the render path reads `snapshot()` instead. Walks the (few) chunks.
  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>? {
    var rel = Int(offset - windowStart)
    guard rel >= 0 else { return nil }
    for chunk in chunks {
      if rel < chunk.count { return chunk[rel] }
      rel -= chunk.count
    }
    return nil
  }

  /// A cheap immutable snapshot of the currently-decoded window, for the render side.
  ///
  /// The decode queue owns and mutates a `SpinBufferSource`; the render callback must never touch it
  /// (it isn't `Sendable`, and it mutates on the decode queue). It publishes a `SpinPCMWindow` — a
  /// `Sendable` `MixSource` the renderer installs on its own serial queue (PHASE_5_PLAN §4 / Codex design
  /// 019feda9). The snapshot shares the immutable chunk list by reference; the next decode appends a NEW
  /// chunk (which only COW-copies the small array-of-references), never the PCM — so this is cheap.
  func snapshot() -> SpinPCMWindow {
    SpinPCMWindow(
      spinID: spinID, startFrame: startFrame, envelope: envelope,
      windowStart: windowStart, chunks: chunks)
  }

  // MARK: - Decode driver (non-render executor)

  /// Highest source offset currently decoded and readable (exclusive upper bound).
  var decodedThroughOffset: Int64 { windowStart + Int64(totalFrames) }

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

  /// Drop whole leading chunks that end at/before `offset` to bound memory (no PCM copy — just releases
  /// the chunk). A partially-covered chunk is kept, so the window may retain up to one extra chunk behind
  /// `offset`; the caller passes a value well behind the render position, so that is safe.
  func discard(beforeSourceOffset offset: Int64) {
    while let first = chunks.first {
      let firstEnd = windowStart + Int64(first.count)
      guard firstEnd <= offset else { break }
      windowStart = firstEnd
      totalFrames -= first.count
      chunks.removeFirst()
    }
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
      var chunk = [SIMD2<Float>]()
      chunk.reserveCapacity(outFrames)
      for i in 0..<outFrames {
        chunk.append(SIMD2(left[i], right[i]))
      }
      chunks.append(chunk)  // immutable once appended — snapshots share it, never copy it
      totalFrames += outFrames
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
  private let chunks: [[SIMD2<Float>]]
  /// Prefix sums of chunk lengths (count + 1 entries); `prefix[i]` = frames before chunk `i`,
  /// `prefix[count]` = total. Lets `stereoFrame` binary-search to the containing chunk.
  private let prefix: [Int]

  init(
    spinID: String, startFrame: Int64, envelope: FadeEnvelope, windowStart: Int64,
    chunks: [[SIMD2<Float>]]
  ) {
    self.spinID = spinID
    self.startFrame = startFrame
    self.envelope = envelope
    self.windowStart = windowStart
    self.chunks = chunks
    var sums = [Int]()
    sums.reserveCapacity(chunks.count + 1)
    var acc = 0
    for chunk in chunks {
      sums.append(acc)
      acc += chunk.count
    }
    sums.append(acc)
    self.prefix = sums
  }

  /// Convenience: wrap a single flat buffer (tests / a one-chunk window).
  init(
    spinID: String, startFrame: Int64, envelope: FadeEnvelope, windowStart: Int64,
    frames: [SIMD2<Float>]
  ) {
    self.init(
      spinID: spinID, startFrame: startFrame, envelope: envelope, windowStart: windowStart,
      chunks: frames.isEmpty ? [] : [frames])
  }

  func stereoFrame(atSourceOffset offset: Int64) -> SIMD2<Float>? {
    let rel = offset - windowStart
    guard rel >= 0, rel < Int64(prefix[prefix.count - 1]) else { return nil }
    let target = Int(rel)
    // Largest chunk index whose prefix <= target.
    var lo = 0
    var hi = chunks.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if prefix[mid] <= target { lo = mid } else { hi = mid - 1 }
    }
    return chunks[lo][target - prefix[lo]]
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
