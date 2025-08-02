import AVFoundation
//
//  AudioBufferTestUtilities.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/22/25.
//
import Foundation

@testable import PlayolaPlayer

/// Provides test utilities for working with audio data in tests
class AudioBufferTestUtilities {

  /// Creates a PCM buffer with the given samples
  /// - Parameters:
  ///   - samples: Array of sample values to include in the buffer
  ///   - format: The audio format to use (defaults to stereo 44.1kHz float32)
  /// - Returns: An initialized AVAudioPCMBuffer or nil if creation fails
  static func createBuffer(
    samples: [Float],
    format: AVAudioFormat? = nil
  ) -> AVAudioPCMBuffer? {
    let audioFormat = format ?? AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: audioFormat,
        frameCapacity: AVAudioFrameCount(samples.count))
    else {
      return nil
    }

    // Copy samples to the buffer
    if let channelData = buffer.floatChannelData {
      for i in 0..<min(samples.count, Int(buffer.frameCapacity)) {
        channelData[0][i] = samples[i]

        // For stereo, copy the same sample to right channel
        if audioFormat.channelCount == 2 {
          channelData[1][i] = samples[i]
        }
      }

      buffer.frameLength = AVAudioFrameCount(min(samples.count, Int(buffer.frameCapacity)))
    }

    return buffer
  }

  /// Extracts samples from a PCM buffer
  /// - Parameters:
  ///   - buffer: The audio buffer to extract samples from
  ///   - channel: Which channel to extract (0 = left, 1 = right, defaults to 0)
  /// - Returns: Array of sample values from the specified channel
  static func extractSamples(
    from buffer: AVAudioPCMBuffer,
    channel: Int = 0
  ) -> [Float] {
    guard let channelData = buffer.floatChannelData,
      channel < buffer.format.channelCount
    else {
      return []
    }

    var samples = [Float]()
    let channelDataPtr = channelData[channel]

    for i in 0..<Int(buffer.frameLength) {
      samples.append(channelDataPtr[i])
    }

    return samples
  }

  /// Generates test audio samples with a specific pattern
  /// - Parameters:
  ///   - pattern: The pattern to generate
  ///   - count: How many samples to generate
  ///   - amplitude: Maximum amplitude of the generated samples
  /// - Returns: Array of sample values
  static func generateTestSamples(
    pattern: SamplePattern,
    count: Int,
    amplitude: Float = 1.0
  ) -> [Float] {
    switch pattern {
    case .sine:
      return generateSineWave(sampleCount: count, amplitude: amplitude)
    case .ramp:
      return generateRamp(sampleCount: count, amplitude: amplitude)
    case .square:
      return generateSquareWave(sampleCount: count, amplitude: amplitude)
    case .noise:
      return generateNoise(sampleCount: count, amplitude: amplitude)
    }
  }

  // MARK: - Sample Generation Patterns

  enum SamplePattern {
    case sine  // Sine wave
    case ramp  // Linear ramp up
    case square  // Square wave
    case noise  // Random noise
  }

  private static func generateSineWave(sampleCount: Int, amplitude: Float) -> [Float] {
    var samples = [Float]()
    let frequency: Float = 440.0  // A4 note
    let sampleRate: Float = 44100.0

    for i in 0..<sampleCount {
      let phase = 2.0 * Float.pi * frequency * Float(i) / sampleRate
      let sample = amplitude * sin(phase)
      samples.append(sample)
    }

    return samples
  }

  private static func generateRamp(sampleCount: Int, amplitude: Float) -> [Float] {
    var samples = [Float]()

    for i in 0..<sampleCount {
      let sample = amplitude * (2.0 * Float(i) / Float(sampleCount - 1) - 1.0)
      samples.append(sample)
    }

    return samples
  }

  private static func generateSquareWave(sampleCount: Int, amplitude: Float) -> [Float] {
    var samples = [Float]()
    let frequency: Float = 440.0  // A4 note
    let sampleRate: Float = 44100.0
    let period = Int(sampleRate / frequency)

    for i in 0..<sampleCount {
      let sample = (i % period) < period / 2 ? amplitude : -amplitude
      samples.append(sample)
    }

    return samples
  }

  private static func generateNoise(sampleCount: Int, amplitude: Float) -> [Float] {
    var samples = [Float]()

    for _ in 0..<sampleCount {
      let randomValue = Float.random(in: -1.0...1.0) * amplitude
      samples.append(randomValue)
    }

    return samples
  }
}
