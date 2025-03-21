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

    /// Handles the audio tap
    private func onTap(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        self.delegate?.player(self, didPlayBuffer: buffer)
    }

    @MainActor
    public static let shared: PlayolaMainMixer = PlayolaMainMixer()
}
