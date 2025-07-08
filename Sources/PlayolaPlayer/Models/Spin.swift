//
//  Spin.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public struct Fade: Codable, Sendable {
  public let atMS: Int
  public let toVolume: Float

  public init(atMS: Int, toVolume: Float) {
    self.atMS = atMS
    self.toVolume = toVolume
  }
}

/// Represents a scheduled playback item with its associated audio content.
///
/// A `Spin` connects:
/// - Scheduling information (when to play)
/// - Audio content (what to play)
/// - Volume transitions (how to play)
///
/// Spins are typically retrieved as part of a station's schedule and managed
/// by the PlayolaStationPlayer.
public struct Spin: Codable, Sendable {
  /// Unique identifier for this spin
  public let id: String

  /// The station this spin belongs to
  public let stationId: String

  /// The scheduled time when this spin should begin playing
  public let airtime: Date

  /// Initial volume level (0.0 to 1.0) when playback begins
  public let startingVolume: Float

  /// When this spin was created on the server
  public let createdAt: Date

  /// When this spin was last updated on the server
  public let updatedAt: Date

  /// The audio content to play for this spin
  public let audioBlock: AudioBlock

  /// Volume transitions that should occur during playback
  public let fades: [Fade]

  /// Related texts associated with this spin (e.g., DJ notes, song explanations)
  public let relatedTexts: [RelatedText]?

  /// Date provider for testing time-dependent behavior
  public var dateProvider: DateProvider! = .shared

  public init(id: String,
              stationId: String,
              airtime: Date,
              startingVolume: Float,
              createdAt: Date,
              updatedAt: Date,
              audioBlock: AudioBlock,
              fades: [Fade],
              relatedTexts: [RelatedText]? = nil,
              dateProvider: DateProvider! = DateProvider.shared) {
    self.id = id
    self.stationId = stationId
    self.airtime = airtime
    self.startingVolume = startingVolume
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.audioBlock = audioBlock
    self.fades = fades
    self.relatedTexts = relatedTexts
    self.dateProvider = dateProvider
  }

  /// Calculated end time for this spin based on airtime plus audio duration
  public var endtime: Date {
    return airtime + TimeInterval(Double(audioBlock.endOfMessageMS) / 1000)
  }

  /// Whether this spin is currently playing, based on current time compared to airtime and endtime
  public var isPlaying: Bool {
    return airtime <= dateProvider.now() &&
    dateProvider.now() <= endtime
  }
  
  private enum CodingKeys: String, CodingKey {
    case id, stationId, airtime, createdAt, updatedAt, audioBlock, fades, startingVolume, relatedTexts
  }

  // Custom decoder to handle dateProvider
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    id = try container.decode(String.self, forKey: .id)
    stationId = try container.decode(String.self, forKey: .stationId)
    airtime = try container.decode(Date.self, forKey: .airtime)
    startingVolume = try container.decode(Float.self, forKey: .startingVolume)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    audioBlock = try container.decode(AudioBlock.self, forKey: .audioBlock)
    fades = try container.decode([Fade].self, forKey: .fades)
    relatedTexts = try container.decodeIfPresent([RelatedText].self, forKey: .relatedTexts)
    
    // Initialize dateProvider with default value
    dateProvider = DateProvider.shared
  }

  // Custom encoder to handle dateProvider
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    
    try container.encode(id, forKey: .id)
    try container.encode(stationId, forKey: .stationId)
    try container.encode(airtime, forKey: .airtime)
    try container.encode(startingVolume, forKey: .startingVolume)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(audioBlock, forKey: .audioBlock)
    try container.encode(fades, forKey: .fades)
    try container.encodeIfPresent(relatedTexts, forKey: .relatedTexts)
  }
}

extension Spin {
  public static var mock: Spin {
    return Schedule.mock.spins[0]
  }
}

// Extension to provide additional mock utilities for testing
extension Spin {
  /// Creates a mock Spin with optional property overrides
  /// - Parameters:
  ///   - id: Optional override for spin ID
  ///   - airtime: Optional override for airtime
  ///   - stationId: Optional override for station ID
  ///   - audioBlock: Optional override for audio block
  ///   - startingVolume: Optional override for starting volume
  ///   - fades: Optional override for fades
  ///   - createdAt: Optional override for created date
  ///   - updatedAt: Optional override for updated date
  ///   - relatedTexts: Optional override for related texts
  ///   - dateProvider: Optional override for date provider
  /// - Returns: A mock Spin with specified overrides
  public static func mockWith(
    id: String? = nil,
    airtime: Date? = nil,
    stationId: String? = nil,
    audioBlock: AudioBlock? = nil,
    startingVolume: Float? = nil,
    fades: [Fade]? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    relatedTexts: [RelatedText]? = nil,
    dateProvider: DateProvider? = nil
  ) -> Spin {
    // Start with the default mock
    let mockSpin = Spin.mock

    // Create new spin with overrides
    var newSpin = Spin(
      id: id ?? mockSpin.id,
      stationId: stationId ?? mockSpin.stationId,
      airtime: airtime ?? mockSpin.airtime,
      startingVolume: startingVolume ?? mockSpin.startingVolume,
      createdAt: createdAt ?? mockSpin.createdAt,
      updatedAt: updatedAt ?? mockSpin.updatedAt,
      audioBlock: audioBlock ?? mockSpin.audioBlock,
      fades: fades ?? mockSpin.fades,
      relatedTexts: relatedTexts ?? mockSpin.relatedTexts
    )

    // Set date provider if specified
    if let provider = dateProvider {
      newSpin.dateProvider = provider
    } else if mockSpin.dateProvider != nil {
      // Otherwise preserve the original provider if it exists
      newSpin.dateProvider = mockSpin.dateProvider
    }

    return newSpin
  }
}

extension Spin: Equatable, Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(audioBlock)
    hasher.combine(airtime)
  }

  public static func == (lhs: Spin, rhs: Spin) -> Bool {
    return lhs.id == rhs.id && lhs.audioBlock == rhs.audioBlock && lhs.airtime == rhs.airtime
  }
}