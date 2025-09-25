//
//  AudioNormalizationCalculator.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 2/7/25.
//
import AVFoundation

struct AudioNormalizationCalculator {
    enum AudioError: Error {
        case fileConversion
        case bufferConversion
    }

    let file: AVAudioFile
    var amplitude: Float?

    public func playerVolume(_ adjustedVolume: Float) -> Float {
        return (amplitude ?? 1.0) * adjustedVolume
    }

    /// Creates an AudioNormalizationCalculator with amplitude calculated on a background thread
    static func create(_ file: AVAudioFile) async -> AudioNormalizationCalculator {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                var calculator = AudioNormalizationCalculator(file: file, calculateNow: false)
                do {
                    let samples = try calculator.getSamples()
                    calculator.amplitude = calculator.getAmplitude(samples)
                } catch {
                    // Report error on main thread
                    await PlayolaErrorReporter.shared.reportError(
                        error,
                        context:
                        "Failed to get audio samples for normalization | File: \(file.url.lastPathComponent) | "
                            + "Format: \(file.processingFormat.description) | Length: \(file.length)",
                        level: .warning
                    )
                }
                continuation.resume(returning: calculator)
            }
        }
    }

    /// Synchronous initializer for backwards compatibility (e.g., tests)
    init(_ file: AVAudioFile) {
        self.file = file
        do {
            let samples = try getSamples()
            amplitude = getAmplitude(samples)
        } catch {
            // Replace print with proper error reporting
            Task {
                await PlayolaErrorReporter.shared.reportError(
                    error,
                    context:
                    "Failed to get audio samples for normalization | File: \(file.url.lastPathComponent) | "
                        + "Format: \(file.processingFormat.description) | Length: \(file.length)",
                    level: .warning
                )
            }
        }
    }

    /// Private initializer used by async factory
    private init(file: AVAudioFile, calculateNow: Bool) {
        self.file = file
        if calculateNow {
            do {
                let samples = try getSamples()
                amplitude = getAmplitude(samples)
            } catch {
                // Error will be handled by caller
            }
        }
    }

    func getSamples() throws -> [Float] {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            let detailedError = AudioError.bufferConversion
            Task {
                await PlayolaErrorReporter.shared.reportError(
                    detailedError,
                    context:
                    "Failed to create PCM buffer | File format: \(file.processingFormat.description) | "
                        + "Frame capacity: \(file.length)",
                    level: .error
                )
            }
            throw detailedError
        }

        do {
            try file.read(into: buffer)
        } catch {
            // Enhance the error with context before throwing
            Task {
                await PlayolaErrorReporter.shared.reportError(
                    error,
                    context:
                    "Failed to read audio file into buffer | File: \(file.url.lastPathComponent) | "
                        + "Format: \(file.processingFormat.description)",
                    level: .error
                )
            }
            throw error
        }

        guard let channelData = buffer.floatChannelData?.pointee else {
            let error = AudioError.bufferConversion
            Task {
                await PlayolaErrorReporter.shared.reportError(
                    error,
                    context:
                    "Failed to get float channel data from buffer | Buffer length: \(buffer.frameLength)",
                    level: .error
                )
            }
            throw error
        }

        let floatArray = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        return floatArray
    }

    func getAmplitude(_ samples: [Float]) -> Float? {
        let absArray = samples.map { abs($0) }
        return absArray.max()
    }
}

// MARK: - Loudness helpers

extension AudioNormalizationCalculator {
    /// Compute the dB offset required to reach target loudness from a given peak amplitude.
    /// If `amplitude` is nil or non‑positive, returns 0 dB.
    /// Formula: gain(dB) = -20 * log10(amplitude)
    static func requiredDbOffsetDb(forAmplitude amplitude: Float?) -> Float {
        guard let amplitude, amplitude > 0 else { return 0 }
        return Float(-20.0 * log10(Double(amplitude)))
    }

    /// Instance convenience accessor that uses the calculator's measured amplitude.
    var requiredDbOffsetDb: Float {
        Self.requiredDbOffsetDb(forAmplitude: amplitude)
    }
}
