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
  var amplitude: Float? = nil

  public func adjustedVolume(_ playerVolume: Float) -> Float {
    guard let amplitude else { return 1.0 }
    return playerVolume / amplitude
  }

  public func playerVolume(_ adjustedVolume: Float) -> Float {
    return (amplitude ?? 1.0) * adjustedVolume
  }

  init(_ file: AVAudioFile) {
    self.file = file
    do {
      let samples = try getSamples()
      self.amplitude = getAmplitude(samples)
    } catch {
      print("Error getting samples")
    }
  }

  func getSamples() throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioError.bufferConversion
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw error
        }
        let floatArray = Array(UnsafeBufferPointer(start: buffer.floatChannelData?.pointee, count:Int(buffer.frameLength)))
        return floatArray
    }

  func getAmplitude(_ samples: [Float]) -> Float? {
    let absArray = samples.map { abs($0) }
    return absArray.max()
  }
}
