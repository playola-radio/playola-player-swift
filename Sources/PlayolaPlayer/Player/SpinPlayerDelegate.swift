//
//  SpinPlayerDelegate.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/8/25.
//
import AVFoundation
import Foundation

/// Handles communicating `Player` events
public protocol SpinPlayerDelegate: AnyObject {
    /// Notifies the `Player` has either started or stopped playing audio
    func player(_ player: SpinPlayer, didChangePlaybackState isPlaying: Bool)

    /// Notifies everytime the `Player` receives a new audio tap event that contains the current time and buffer of audio data played
    func player(_ player: SpinPlayer,
                didPlayFile file: AVAudioFile,
                atTime time: TimeInterval,
                withBuffer buffer: AVAudioPCMBuffer)
}
