//
//  PlayolaMainMixer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//

import AVFoundation
import Foundation
import os.log

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
            self.engine.connect(self.mixerNode,
                                to: self.engine.mainMixerNode,
                                format: TapProperties.default.format)
            self.engine.prepare()

            self.mixerNode.installTap(onBus: 0,
                                      bufferSize: TapProperties.default.bufferSize,
                                      format: TapProperties.default.format,
                                      block: self.onTap(_:_:))
        } catch {
            Task { @MainActor in
                errorReporter.reportError(error, context: "Failed to initialize PlayolaMainMixer", level: .critical)
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
            try? session.setActive(false, options: .notifyOthersOnDeactivation)

            // Configure for playback category
            try session.setCategory(
                .playback,
                mode: .default,
                options: [
                    .allowBluetoothA2DP,
                    .allowAirPlay,
                ]
            )

            // Set the audio session active
            try session.setActive(true)
            isAudioSessionConfigured = true

            os_log("Audio session successfully configured", log: PlayolaMainMixer.logger, type: .info)
        } catch {
            Task { @MainActor in
                errorReporter.reportError(error, context: "Failed to configure audio session", level: .critical)
            }
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
