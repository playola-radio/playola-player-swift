import AVFoundation
//
//  AVAudioFileMock.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/22/25.
//
import Foundation

@testable import PlayolaPlayer

// Create a cleaner solution using composition instead of inheritance
class AVAudioFileMock {
  // Custom properties for the mock
  var mockSamples: [Float] = []
  var mockLength: AVAudioFramePosition = 0
  var mockBuffer: AVAudioPCMBuffer?
  var mockFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
  var mockURL = URL(string: "https://example.com/audio.mp3")!
  var shouldThrowReadError = false

  // Properties that match AVAudioFile's interface
  var length: AVAudioFramePosition {
    return mockLength
  }

  var processingFormat: AVAudioFormat {
    return mockFormat
  }

  var url: URL {
    return mockURL
  }

  // Initialize a mock with sample data
  init(samples: [Float]) {
    self.mockSamples = samples
    self.mockLength = AVAudioFramePosition(samples.count)

    // Create a mock buffer with our samples
    mockBuffer = createBufferWithSamples(samples)
  }

  // Create a mock PCM buffer with given samples
  private func createBufferWithSamples(_ samples: [Float]) -> AVAudioPCMBuffer? {
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: mockFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else {
      return nil
    }

    if let channelData = buffer.floatChannelData {
      // Copy the samples to the buffer
      for i in 0..<min(Int(buffer.frameCapacity), samples.count) {
        channelData[0][i] = samples[i]
      }
      buffer.frameLength = AVAudioFrameCount(min(Int(buffer.frameCapacity), samples.count))
    }

    return buffer
  }

  // Implementation of AVAudioFile's read method
  func read(into buffer: AVAudioPCMBuffer) throws {
    if shouldThrowReadError {
      throw NSError(
        domain: "AVAudioFileMockError", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Mock read error"])
    }

    guard let mockBuffer = self.mockBuffer else {
      throw NSError(
        domain: "AVAudioFileMockError", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "No mock buffer available"])
    }

    // Copy data from mock buffer to the provided buffer
    if let destChannelData = buffer.floatChannelData,
      let sourceChannelData = mockBuffer.floatChannelData
    {
      let frameCount = min(buffer.frameCapacity, mockBuffer.frameLength)
      for i in 0..<Int(frameCount) {
        destChannelData[0][i] = sourceChannelData[0][i]
      }
      buffer.frameLength = frameCount
    }
  }
}
