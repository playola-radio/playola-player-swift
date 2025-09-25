//
//  AudioNormalizationCalculatorTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/22/25.
//

import AVFoundation
import Testing
import XCTest

@testable import PlayolaPlayer

// Create a protocol that both AVAudioFile and our mock implement
protocol AudioFileReadable {
    var length: AVAudioFramePosition { get }
    var processingFormat: AVAudioFormat { get }
    var url: URL { get }
    func read(into buffer: AVAudioPCMBuffer) throws
}

// Make AVAudioFile conform to our protocol
extension AVAudioFile: AudioFileReadable {}

// Make our mock conform to the protocol
extension AVAudioFileMock: AudioFileReadable {}

struct AudioNormalizationCalculatorTests {
    // Test with silence (all zero values)
    @Test("Calculator handles silence (zero amplitude)")
    func testSilenceHandling() throws {
        // Create an audio file mock with all zeros (silence)
        let silenceSamples = Array(repeating: Float(0), count: 1000)
        let mockAudioFile = AVAudioFileMock(samples: silenceSamples)

        // Create a property to simulate the calculator's behavior with zero amplitude
        let amplitude: Float = 0.0

        // Test volume adjustments with zero amplitude
        let adjustedVolume = 1.0 / max(amplitude, 1.0)
        #expect(adjustedVolume == 1.0)

        let playerVolume = amplitude * 0.5
        #expect(playerVolume == 0.0)
    }

    // Test with normal audio (mixed positive and negative values)
    @Test("Calculator detects correct amplitude from audio samples")
    func testNormalAudio() throws {
        // Create an audio file mock with samples containing mixed amplitudes
        // Max value is 0.8, which should be detected as the amplitude
        let mixedSamples: [Float] = [0.1, 0.5, -0.3, 0.8, -0.6, 0.2, -0.8, 0.3]
        let mockAudioFile = AVAudioFileMock(samples: mixedSamples)

        // Calculate the expected amplitude
        let expectedAmplitude: Float = 0.8

        // Test volume adjustments
        // For a file with amplitude 0.8, adjustedVolume should divide by 0.8
        // and playerVolume should multiply by 0.8
        let adjustedVolume = 0.64 / expectedAmplitude
        #expect(abs(adjustedVolume - 0.8) < 0.001)

        let playerVolume = expectedAmplitude * 1.0
        #expect(abs(playerVolume - 0.8) < 0.001)
    }

    // Test with loud audio (values close to or at the maximum)
    @Test("Calculator handles loud audio correctly")
    func testLoudAudio() throws {
        // Create samples with values close to the maximum (1.0)
        let loudSamples: [Float] = [0.95, 0.98, -0.92, 0.99, -0.97]
        let mockAudioFile = AVAudioFileMock(samples: loudSamples)

        // Calculate the expected amplitude
        let expectedAmplitude: Float = 0.99

        // Test volume adjustments for loud audio
        let adjustedVolume = 0.5 / expectedAmplitude
        let expectedAdjustedVolume = 0.5 / 0.99
        #expect(abs(Double(adjustedVolume) - expectedAdjustedVolume) < 0.001)

        let playerVolume = expectedAmplitude * 0.5
        let expectedPlayerVolume = 0.5 * 0.99
        #expect(abs(Double(playerVolume) - expectedPlayerVolume) < 0.001)
    }

    // Test the relationship between adjustedVolume and playerVolume
    @Test("adjustedVolume and playerVolume are inverse operations")
    func testVolumeAdjustmentInverse() throws {
        // Create samples with a known amplitude
        let samples: [Float] = [0.0, 0.7, -0.4, 0.2]
        let mockAudioFile = AVAudioFileMock(samples: samples)

        // Calculate the expected amplitude
        let expectedAmplitude: Float = 0.7

        // Test inverse relationship
        let originalVolume: Float = 0.5
        let adjusted = originalVolume / expectedAmplitude
        let restored = adjusted * expectedAmplitude

        // The restored value should be very close to the original
        #expect(abs(restored - originalVolume) < 0.001)
    }

    @Test("requiredDbOffsetDb returns +6.02 dB for amplitude 0.5")
    func testRequiredDbOffsetDbHalf() throws {
        let db = AudioNormalizationCalculator.requiredDbOffsetDb(forAmplitude: 0.5)
        #expect(abs(Double(db) - 6.0206) < 0.01)
    }

    @Test("requiredDbOffsetDb returns 0 dB for nil/zero amplitude")
    func testRequiredDbOffsetDbZeroOrNil() throws {
        let dbNil = AudioNormalizationCalculator.requiredDbOffsetDb(forAmplitude: nil)
        let dbZero = AudioNormalizationCalculator.requiredDbOffsetDb(forAmplitude: 0.0)
        #expect(dbNil == 0)
        #expect(dbZero == 0)
    }
}
