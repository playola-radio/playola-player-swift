//
//  MainMixerProvider.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/21/25.
//
import AVFoundation

/// Protocol defining the interface for main audio mixer operations
public protocol MainMixerProvider: AnyObject {
    /// The mixer node used for audio mixing
    var mixerNode: AVAudioMixerNode { get }

    /// The main audio engine
    var engine: AVAudioEngine { get }

    /// Configures the audio session for playback
    func configureAudioSession()

    /// Deactivates the audio session when it's no longer needed
    func deactivateAudioSession()
}
