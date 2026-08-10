import AVFoundation
import CoreMedia
import Foundation

/// Authors a `CMSampleBuffer` from a `RenderBuffer` (interleaved stereo float32 PCM on the station
/// timeline). Specifies the exact ASBD, format description, block-buffer backing, and sample timing the
/// `AVSampleBufferAudioRenderer` requires (PHASE_5_PLAN §12/C12). Pure with respect to the render sink,
/// so it is unit-testable on macOS without a device.
enum SampleBufferAuthoring {
  static func makeSampleBuffer(from buffer: RenderBuffer) -> CMSampleBuffer? {
    let frameCount = buffer.frameCount
    guard frameCount > 0 else { return nil }
    let bytesPerFrame = 8  // 2 channels * 4 bytes (float32), interleaved

    var asbd = AudioStreamBasicDescription(
      mSampleRate: buffer.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(bytesPerFrame),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(bytesPerFrame),
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0)

    var formatDescription: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &formatDescription) == noErr,
      let formatDescription
    else { return nil }

    let dataByteSize = frameCount * bytesPerFrame
    var blockBuffer: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataByteSize,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: dataByteSize, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
      let blockBuffer
    else { return nil }

    let copyStatus = buffer.frames.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(
        with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataByteSize)
    }
    guard copyStatus == kCMBlockBufferNoErr else { return nil }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(buffer.sampleRate)),
      presentationTimeStamp: buffer.presentationTimeStamp,
      decodeTimeStamp: .invalid)
    var sampleSize = bytesPerFrame

    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
        sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer) == noErr
    else { return nil }

    return sampleBuffer
  }
}

/// Live `RenderSynchronizing` + `SampleBufferRendering` over one `AVSampleBufferRenderSynchronizer` and
/// one `AVSampleBufferAudioRenderer`. The SDK owns the media stack here but NOT the `AVAudioSession`
/// (host-owned — that is exactly what lets this route AirPlay-2 long-form). Device-verified separately.
final class LiveSampleBufferSink {
  let synchronizer = AVSampleBufferRenderSynchronizer()
  let renderer = AVSampleBufferAudioRenderer()

  init() {
    synchronizer.addRenderer(renderer)
  }
}

final class LiveRenderSynchronizer: RenderSynchronizing {
  private let synchronizer: AVSampleBufferRenderSynchronizer

  init(_ synchronizer: AVSampleBufferRenderSynchronizer) {
    self.synchronizer = synchronizer
  }

  var currentTime: CMTime { synchronizer.currentTime() }

  func setRate(_ rate: Float, time: CMTime) {
    synchronizer.setRate(rate, time: time)
  }

  func addBoundaryObserver(
    forTimes times: [CMTime], _ block: @escaping @Sendable () -> Void
  ) -> Any {
    synchronizer.addBoundaryTimeObserver(
      forTimes: times.map { NSValue(time: $0) }, queue: nil, using: block)
  }

  func removeObserver(_ token: Any) {
    synchronizer.removeTimeObserver(token)
  }
}

final class LiveSampleBufferRenderer: SampleBufferRendering {
  private let renderer: AVSampleBufferAudioRenderer

  init(_ renderer: AVSampleBufferAudioRenderer) {
    self.renderer = renderer
  }

  var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

  func enqueue(_ buffer: RenderBuffer) {
    guard let sampleBuffer = SampleBufferAuthoring.makeSampleBuffer(from: buffer) else { return }
    renderer.enqueue(sampleBuffer)
  }

  func flush() {
    renderer.flush()
  }

  func requestMediaDataWhenReady(
    on queue: DispatchQueue, using block: @escaping @Sendable () -> Void
  ) {
    renderer.requestMediaDataWhenReady(on: queue, using: block)
  }

  func stopRequestingMediaData() {
    renderer.stopRequestingMediaData()
  }
}
