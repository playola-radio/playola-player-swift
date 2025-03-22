//
//  AudioNormalizationWaveformTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/22/25.
//
import XCTest
import Testing
import AVFoundation
@testable import PlayolaPlayer

struct AudioNormalizationWaveformTests {

  // For each test we'll directly test the math that the AudioNormalizationCalculator would perform

  @Test("Testing with a sine wave")
  func testSineWave() throws {
    // Generate a sine wave with amplitude 0.8
    let sineWaveSamples = AudioBufferTestUtilities.generateTestSamples(
      pattern: .sine,
      count: 1000,
      amplitude: 0.8
    )

    // Calculate the actual maximum amplitude of the samples
    let actualMaxAmplitude = sineWaveSamples.map { abs($0) }.max() ?? 0

    // Typically a sine wave won't hit exactly the requested amplitude due to discrete sampling
    #expect(actualMaxAmplitude <= 0.8)
    #expect(actualMaxAmplitude > 0.7)

    // Test the volume adjustment equations directly
    let inputVolume: Float = 0.5
    let adjustedVolume = inputVolume / actualMaxAmplitude

    // Verify that adjustedVolume * amplitude = original input
    #expect(abs(adjustedVolume * actualMaxAmplitude - inputVolume) < 0.001)
  }

  @Test("Testing with a square wave")
  func testSquareWave() throws {
    // Generate a square wave with amplitude 0.6
    let squareWaveSamples = AudioBufferTestUtilities.generateTestSamples(
      pattern: .square,
      count: 1000,
      amplitude: 0.6
    )

    // Square waves have consistent amplitude
    let actualMaxAmplitude = squareWaveSamples.map { abs($0) }.max() ?? 0
    #expect(abs(actualMaxAmplitude - 0.6) < 0.001)

    // Test the volume adjustment math
    let playerVolume = actualMaxAmplitude * 0.8  // 0.8 is the requested volume
    #expect(abs(playerVolume - 0.48) < 0.001)
  }

  @Test("Testing with a ramp wave")
  func testRampWave() throws {
    // Generate a ramp from -0.7 to 0.7
    let rampSamples = AudioBufferTestUtilities.generateTestSamples(
      pattern: .ramp,
      count: 1000,
      amplitude: 0.7
    )

    // Calculate the actual maximum amplitude
    let actualMaxAmplitude = rampSamples.map { abs($0) }.max() ?? 0
    #expect(abs(actualMaxAmplitude - 0.7) < 0.001)

    // The adjusted volume should be the input volume divided by the amplitude
    let adjustedVolume = 0.5 / actualMaxAmplitude
    #expect(abs(adjustedVolume - (0.5 / 0.7)) < 0.001)
  }

  @Test("Testing with random noise")
  func testNoise() throws {
    // Generate random noise with max amplitude 0.5
    let noiseSamples = AudioBufferTestUtilities.generateTestSamples(
      pattern: .noise,
      count: 1000,
      amplitude: 0.5
    )

    // Find the actual maximum amplitude in the noise
    let actualMaxAmplitude = noiseSamples.map { abs($0) }.max() ?? 0
    #expect(actualMaxAmplitude <= 0.5)

    // The player volume at a requested level of 1.0 should be the same as the amplitude
    let playerVolume = actualMaxAmplitude * 1.0
    #expect(playerVolume == actualMaxAmplitude)
  }

  @Test("Testing consistent volume normalization across waveforms")
  func testConsistentNormalization() throws {
    // Generate different waveforms with different amplitudes
    let sineWave = AudioBufferTestUtilities.generateTestSamples(pattern: .sine, count: 1000, amplitude: 0.9)
    let squareWave = AudioBufferTestUtilities.generateTestSamples(pattern: .square, count: 1000, amplitude: 0.7)
    let rampWave = AudioBufferTestUtilities.generateTestSamples(pattern: .ramp, count: 1000, amplitude: 0.5)
    let noiseWave = AudioBufferTestUtilities.generateTestSamples(pattern: .noise, count: 1000, amplitude: 0.3)

    // Find the maximum amplitude of each waveform
    let sineAmplitude = sineWave.map { abs($0) }.max() ?? 0
    let squareAmplitude = squareWave.map { abs($0) }.max() ?? 0
    let rampAmplitude = rampWave.map { abs($0) }.max() ?? 0
    let noiseAmplitude = noiseWave.map { abs($0) }.max() ?? 0

    // Target volume we want for all waveforms
    let targetVolume: Float = 0.8

    // Calculate the adjusted input volume needed for each waveform to reach the target
    let sineAdjusted = targetVolume / sineAmplitude
    let squareAdjusted = targetVolume / squareAmplitude
    let rampAdjusted = targetVolume / rampAmplitude
    let noiseAdjusted = targetVolume / noiseAmplitude

    // Verify that with these adjusted volumes, all waveforms would play at the same volume
    let sineResult = sineAmplitude * sineAdjusted
    let squareResult = squareAmplitude * squareAdjusted
    let rampResult = rampAmplitude * rampAdjusted
    let noiseResult = noiseAmplitude * noiseAdjusted

    #expect(abs(sineResult - targetVolume) < 0.001)
    #expect(abs(squareResult - targetVolume) < 0.001)
    #expect(abs(rampResult - targetVolume) < 0.001)
    #expect(abs(noiseResult - targetVolume) < 0.001)
  }
}
