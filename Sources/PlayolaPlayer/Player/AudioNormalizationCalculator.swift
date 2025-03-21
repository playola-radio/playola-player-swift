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
      // Replace print with proper error reporting
      Task { @MainActor in
        PlayolaErrorReporter.shared.reportError(
          error,
          context: "Failed to get audio samples for normalization | File: \(file.url.lastPathComponent) | Format: \(file.processingFormat.description) | Length: \(file.length)",
          level: .warning)
      }
    }
  }
  
  func getSamples() throws -> [Float] {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
      let detailedError = AudioError.bufferConversion
      Task { @MainActor in
        PlayolaErrorReporter.shared.reportError(detailedError,
                                                context: "Failed to create PCM buffer | File format: \(file.processingFormat.description) | Frame capacity: \(file.length)",
                                                level: .error)
      }
      throw detailedError
    }
    
    do {
      try file.read(into: buffer)
    } catch {
      // Enhance the error with context before throwing
      Task { @MainActor in
        PlayolaErrorReporter.shared.reportError(error,
                                                context: "Failed to read audio file into buffer | File: \(file.url.lastPathComponent) | Format: \(file.processingFormat.description)",
                                                level: .error)
      }
      throw error
    }
    
    guard let channelData = buffer.floatChannelData?.pointee else {
      let error = AudioError.bufferConversion
      Task { @MainActor in
        PlayolaErrorReporter.shared.reportError(
          error,
          context: "Failed to get float channel data from buffer | Buffer length: \(buffer.frameLength)",
          level: .error)
      }
      throw error
    }
    
    let floatArray = Array(UnsafeBufferPointer(start: channelData, count:Int(buffer.frameLength)))
    return floatArray
  }
  
  func getAmplitude(_ samples: [Float]) -> Float? {
    let absArray = samples.map { abs($0) }
    return absArray.max()
  }
}
