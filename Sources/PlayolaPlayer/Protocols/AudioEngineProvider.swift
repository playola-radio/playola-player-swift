//
//  AudioEngineProviderProtocol.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/21/25.
//
import AVFoundation

/// Protocol defining the interface for audio engine operations
public protocol AudioEngineProvider {
  /// Starts the audio engine
  /// - Throws: An error if the engine cannot be started
  func start() throws

  /// Attaches a player node to the audio engine
  /// - Parameter node: The AVAudioPlayerNode to attach
  func attach(_ node: AVAudioPlayerNode)

  /// Connects a player node to a mixer node
  /// - Parameters:
  ///   - playerNode: The source AVAudioPlayerNode
  ///   - mixerNode: The destination AVAudioMixerNode
  ///   - format: The audio format for the connection
  func connect(
    _ playerNode: AVAudioPlayerNode, to mixerNode: AVAudioMixerNode, format: AVAudioFormat?)

  /// Prepares the audio engine for playback
  func prepare()
}
