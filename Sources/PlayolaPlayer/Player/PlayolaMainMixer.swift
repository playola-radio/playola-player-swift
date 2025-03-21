//
//  PlayolaMainMixer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//

import AVFoundation
import Foundation
import os.log
import UIKit

public protocol PlayolaMainMixerDelegate {
  func player(_ mainMixer: PlayolaMainMixer, didPlayBuffer: AVAudioPCMBuffer)
}

/// Default properties for the tap
enum TapProperties {
  case `default`
  
  /// The amount of samples in each buffer of audio
  var bufferSize: AVAudioFrameCount {
    return 512
  }
  
  /// The format of the audio in the tap (desired is float 32, non-interleaved)
  var format: AVAudioFormat {
    return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
  }
}

open class PlayolaMainMixer: NSObject {
  open var mixerNode: AVAudioMixerNode!
  open var engine: AVAudioEngine!
  open var delegate: PlayolaMainMixerDelegate?
  private let errorReporter = PlayolaErrorReporter.shared
  private var isAudioSessionConfigured = false
  
  private static let logger = OSLog(subsystem: "fm.playola.playolaCore", category: "MainMixer")
  
  override init() {
    super.init()
    do {
      self.mixerNode = AVAudioMixerNode()
      self.engine = AVAudioEngine()
      self.engine.attach(self.mixerNode)
      
      do {
        self.engine.connect(self.mixerNode,
                            to: self.engine.mainMixerNode,
                            format: TapProperties.default.format)
      } catch {
        Task { @MainActor in
          errorReporter.reportError(error,
                                    context: "Failed to connect mixer nodes: \(error.localizedDescription)",
                                    level: .critical)
        }
        throw error
      }
      
      self.engine.prepare()
      
      do {
        self.mixerNode.installTap(onBus: 0,
                                  bufferSize: TapProperties.default.bufferSize,
                                  format: TapProperties.default.format,
                                  block: self.onTap(_:_:))
      } catch {
        Task { @MainActor in
          errorReporter.reportError(error,
                                    context: "Failed to install tap on mixer node: \(error.localizedDescription)",
                                    level: .critical)
        }
        throw error
      }
    } catch {
      Task { @MainActor in
        errorReporter.reportError(error,
                                  context: "Critical failure initializing PlayolaMainMixer: \(error.localizedDescription)",
                                  level: .critical)
      }
    }
  }
  
  deinit {
    do {
      self.mixerNode.removeTap(onBus: 0)
    } catch {
      // Cannot report via errorReporter in deinit as it might be async
      // For deinit errors, we'll keep using os_log
      os_log("Error removing tap during deinit: %@", log: PlayolaMainMixer.logger, type: .error, error.localizedDescription)
    }
  }
  
  /// Configures the shared audio session for playback
  public func configureAudioSession() {
    guard !isAudioSessionConfigured else { return }
    
    do {
      let session = AVAudioSession.sharedInstance()
      
      // First deactivate with appropriate options to reset state
      do {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        // This is not a critical error, just log it
        Task { @MainActor in
          errorReporter.reportError(error,
                                    context: "Non-critical: Failed to deactivate audio session before configuration",
                                    level: .warning)
        }
        // Continue with configuration
      }
      
      // Configure for playback category
      do {
        try session.setCategory(
          .playback,
          mode: .default,
          options: [
            .allowBluetoothA2DP,
            .allowAirPlay,
          ]
        )
      } catch {
        Task { @MainActor in
          let deviceName = UIDevice.current.name
          let systemVersion = UIDevice.current.systemVersion
          errorReporter.reportError(error,
                                    context: "Failed to set audio session category | Device: \(deviceName) | iOS: \(systemVersion)",
                                    level: .critical)
        }
        throw error
      }
      
      // Set the audio session active
      do {
        try session.setActive(true)
        isAudioSessionConfigured = true
        os_log("Audio session successfully configured", log: PlayolaMainMixer.logger, type: .info)
      } catch {
        Task { @MainActor in
          let deviceName = UIDevice.current.name
          let systemVersion = UIDevice.current.systemVersion
          let currentRoute = session.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
          
          errorReporter.reportError(error,
                                    context: "Failed to activate audio session | Device: \(deviceName) | iOS: \(systemVersion) | Route: \(currentRoute)",
                                    level: .critical)
        }
        throw error
      }
    } catch {
      Task { @MainActor in
        errorReporter.reportError(error,
                                  context: "Critical error configuring audio session: \(error.localizedDescription)",
                                  level: .critical)
      }
      // Don't set isAudioSessionConfigured to true since we failed
    }
  }
  
  /// Deactivates the audio session when it's no longer needed
  public func deactivateAudioSession() {
    guard isAudioSessionConfigured else { return }
    
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setActive(false, options: .notifyOthersOnDeactivation)
      isAudioSessionConfigured = false
      
      os_log("Audio session deactivated", log: PlayolaMainMixer.logger, type: .info)
    } catch {
      Task { @MainActor in
        errorReporter.reportError(error, context: "Failed to deactivate audio session", level: .warning)
      }
    }
  }
  
  /// Handle audio session interruptions such as phone calls
  public func handleAudioSessionInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }
    
    switch type {
    case .began:
      // Audio session was interrupted - might need to pause playback
      os_log("Audio session interrupted", log: PlayolaMainMixer.logger, type: .info)
      
    case .ended:
      // Interruption ended - might need to resume playback
      guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
        return
      }
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      
      if options.contains(.shouldResume) {
        // The system indicates that we can resume audio
        do {
          try engine.start()
          os_log("Audio engine restarted after interruption", log: PlayolaMainMixer.logger, type: .info)
        } catch {
          Task { @MainActor in
            errorReporter.reportError(error, context: "Failed to restart audio engine after interruption", level: .error)
          }
        }
      }
      
    @unknown default:
      os_log("Unknown audio session interruption type: %d", log: PlayolaMainMixer.logger, type: .error, typeValue)
    }
  }
  
  /// Handle audio route changes such as connecting/disconnecting headphones
  public func handleAudioRouteChange(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }
    
    // Check if the audio route changed
    switch reason {
    case .newDeviceAvailable:
      // New device (like headphones) was connected
      os_log("New audio route device available", log: PlayolaMainMixer.logger, type: .info)
      
    case .oldDeviceUnavailable:
      // Old device (like headphones) was disconnected
      // You might want to pause playback here
      os_log("Audio route device disconnected", log: PlayolaMainMixer.logger, type: .info)
      
    default:
      // Handle other route changes if needed
      os_log("Audio route changed for reason: %d", log: PlayolaMainMixer.logger, type: .info, reasonValue)
    }
  }
  
  /// Handles the audio tap
  private func onTap(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
    self.delegate?.player(self, didPlayBuffer: buffer)
  }
  
  @MainActor
  public static let shared: PlayolaMainMixer = PlayolaMainMixer()
}
