import CoreMedia
import Foundation

/// One block of mixed program PCM authored on the station timeline, handed to the render sink.
///
/// The mixer produces these; the sink adapter turns each into a `CMSampleBuffer` and enqueues it on the
/// `AVSampleBufferAudioRenderer`. `frames` is interleaved stereo float32 (its memory layout is exactly
/// L,R,L,R…), so the sink copies it straight into a `CMBlockBuffer` with no conversion. `startFrame` is
/// the mix-timeline frame of the first sample, which fixes the buffer's absolute PTS.
struct RenderBuffer: Sendable, Equatable {
  let startFrame: Int64
  let sampleRate: Double
  let frames: [SIMD2<Float>]

  var frameCount: Int { frames.count }
  var presentationTimeStamp: CMTime { CMTime(value: startFrame, timescale: Int32(sampleRate)) }
  var duration: CMTime { CMTime(value: Int64(frames.count), timescale: Int32(sampleRate)) }
}

/// Behaviour of `AVSampleBufferRenderSynchronizer`, wrapped so the render pipeline is unit-testable
/// without CoreMedia. The fake records `setRate`/time and fires boundary observers deterministically.
protocol RenderSynchronizing: AnyObject {
  var currentTime: CMTime { get }
  func setRate(_ rate: Float, time: CMTime)
  func addBoundaryObserver(forTimes times: [CMTime], _ block: @escaping @Sendable () -> Void) -> Any
  func removeObserver(_ token: Any)
}

/// Behaviour of `AVSampleBufferAudioRenderer` (`AVQueuedSampleBufferRendering`), wrapped so the pipeline
/// is unit-testable. The classic `requestMediaDataWhenReady` + `enqueue` surface is the correct,
/// non-deprecated iOS 18 audio path (PHASE_5_PLAN §12/C1). The fake records enqueued buffers, toggles
/// readiness, and captures the request block so a test can pump the loop.
protocol SampleBufferRendering: AnyObject {
  var isReadyForMoreMediaData: Bool { get }
  func enqueue(_ buffer: RenderBuffer)
  func flush()
  func requestMediaDataWhenReady(
    on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
  func stopRequestingMediaData()
}
