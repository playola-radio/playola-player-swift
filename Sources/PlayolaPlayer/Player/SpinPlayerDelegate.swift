//
//  SpinPlayerDelegate.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/8/25.
//
import AVFoundation
import Foundation

/// Handles communicating `Player` events
@MainActor
public protocol SpinPlayerDelegate: AnyObject {
    /// Notifies the `Player` has either started or stopped playing audio
    func player(_ player: SpinPlayer, startedPlaying spin: Spin)

    /// Notifies everytime the `Player` receives a new audio tap event that contains the current time and buffer of
    /// audio data played
    func player(
        _ player: SpinPlayer,
        didPlayFile file: AVAudioFile,
        atTime time: TimeInterval,
        withBuffer buffer: AVAudioPCMBuffer
    )

    func player(_ player: SpinPlayer, didChangeState state: SpinPlayer.State)
}
