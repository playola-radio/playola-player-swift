//  SampleBufferAuthoringTests.swift
//  PlayolaPlayer
//
//  Phase 5 — Lane C. Verifies RenderBuffer -> CMSampleBuffer authoring
//  (ASBD, PTS, sample count, backing PCM) on macOS, without a device or an
//  actual AVSampleBufferAudioRenderer.

import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import PlayolaPlayer

struct SampleBufferAuthoringTests {
  @Test("authors a CMSampleBuffer with the expected PTS, sample count and format")
  func authorsSampleBuffer() throws {
    let frames = (0..<100).map { SIMD2<Float>(Float($0) / 100, -Float($0) / 100) }
    let buffer = RenderBuffer(startFrame: 48_000, sampleRate: 48_000, frames: frames)

    let sample = try #require(SampleBufferAuthoring.makeSampleBuffer(from: buffer))

    #expect(CMSampleBufferGetNumSamples(sample) == 100)

    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    #expect(abs(CMTimeGetSeconds(pts) - 1.0) < 0.0001)  // 48000 / 48000 == 1.0s

    let format = try #require(CMSampleBufferGetFormatDescription(sample))
    let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    #expect(asbd.mSampleRate == 48_000)
    #expect(asbd.mChannelsPerFrame == 2)
    #expect(asbd.mBitsPerChannel == 32)
    #expect(asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)
  }

  @Test("backing PCM round-trips the interleaved stereo samples")
  func backingDataRoundTrips() throws {
    let frames: [SIMD2<Float>] = [SIMD2(0.25, -0.5), SIMD2(0.75, -1.0)]
    let buffer = RenderBuffer(startFrame: 0, sampleRate: 48_000, frames: frames)
    let sample = try #require(SampleBufferAuthoring.makeSampleBuffer(from: buffer))
    let block = try #require(CMSampleBufferGetDataBuffer(sample))

    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    #expect(
      CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
        dataPointerOut: &dataPointer) == kCMBlockBufferNoErr)
    #expect(length == 2 * 8)  // 2 frames * 8 bytes

    let floats = try #require(dataPointer).withMemoryRebound(to: Float.self, capacity: 4) {
      Array(UnsafeBufferPointer(start: $0, count: 4))
    }
    #expect(floats == [0.25, -0.5, 0.75, -1.0])  // interleaved L,R,L,R
  }

  @Test("an empty render buffer produces no sample buffer")
  func emptyBufferIsNil() {
    let buffer = RenderBuffer(startFrame: 0, sampleRate: 48_000, frames: [])
    #expect(SampleBufferAuthoring.makeSampleBuffer(from: buffer) == nil)
  }
}
