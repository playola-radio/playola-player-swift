//
//  Spin.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public struct Fade: Codable, Sendable, Equatable {
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
  public var dateProvider: DateProviderProtocol! = DateProvider()

  public init(
    id: String,
    stationId: String,
    airtime: Date,
    startingVolume: Float,
    createdAt: Date,
    updatedAt: Date,
    audioBlock: AudioBlock,
    fades: [Fade],
    relatedTexts: [RelatedText]? = nil,
    dateProvider: DateProviderProtocol? = nil
  ) {
    self.id = id
    self.stationId = stationId
    self.airtime = airtime
    self.startingVolume = startingVolume
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.audioBlock = audioBlock
    self.fades = fades.sorted { $0.atMS < $1.atMS }
    self.relatedTexts = relatedTexts
    self.dateProvider = dateProvider ?? DateProvider()
  }

  /// Calculated end time for this spin based on airtime plus audio duration
  public var endtime: Date {
    return airtime + TimeInterval(Double(audioBlock.endOfMessageMS) / 1000)
  }

  /// Whether this spin is currently playing, based on current time compared to airtime and endtime
  public var isPlaying: Bool {
    return airtime <= dateProvider.now() && dateProvider.now() <= endtime
  }

  /// Represents the playback state of a spin relative to the current time
  public enum PlaybackTiming {
    case future  // Spin hasn't started yet
    case playing  // Spin is currently playing
    case tooLateToStart  // Spin has passed but still has time worth playing (>= 2 seconds)
    case past  // Spin has finished or has less than 2 seconds remaining
  }

  /// Minimum duration (in seconds) required to make playing a spin worthwhile
  private static let minimumPlayableDuration: TimeInterval = 2.0

  /// Determines the playback timing state of the spin
  public var playbackTiming: PlaybackTiming {
    let now = dateProvider.now()

    if now < airtime {
      return .future
    } else if now <= endtime {
      // Check if there's enough time left to make playing worthwhile
      let remainingTime = endtime.timeIntervalSince(now)
      if remainingTime < Self.minimumPlayableDuration {
        return .past
      } else {
        return .playing
      }
    } else {
      // We're past the endtime
      return .past
    }
  }

  /// Calculates the volume that should be applied at a given millisecond offset into the spin
  /// - Parameter milliseconds: The number of milliseconds since the start of the spin
  /// - Returns: The volume level (0.0 to 1.0) that should be applied at this point
  public func volumeAtMS(_ milliseconds: Int) -> Float {
    // Start with the initial volume
    var currentVolume = startingVolume

    // Apply all fades that should have occurred by this point
    // Fades are already sorted by atMS in the initializer
    for fade in fades {
      if fade.atMS <= milliseconds {
        currentVolume = fade.toVolume
      } else {
        // Since fades are sorted, we can break early
        break
      }
    }

    return currentVolume
  }

  /// Calculates the *perceived* volume at a given millisecond offset into the spin with a small look‑ahead.
  /// If the next fade occurs within 3 seconds, we return that fade's target as the initial level
  /// (useful when starting mid‑file and you want to land on the “soon imminent” level).
  /// - Parameter ms: Milliseconds since the start of the spin (negative values are treated as 0)
  /// - Returns: The volume level (0.0 to 1.0) to use at this point, with 3s look‑ahead
  public func volumeAt(_ ms: Int) -> Float {
    let milliseconds = max(0, ms)

    // Current volume at this instant (no look‑ahead)
    var currentVolume = startingVolume
    var nextFade: Fade?

    for fade in fades {  // fades are sorted in init
      if fade.atMS <= milliseconds {
        currentVolume = fade.toVolume
      } else {
        nextFade = fade
        break
      }
    }

    // If the next fade is within 3 seconds, prefer its target as the starting point
    if let nf = nextFade {
      let delta = nf.atMS - milliseconds
      if delta <= 3000 {  // within 3s (inclusive)
        return nf.toVolume
      }
    }

    return currentVolume
  }

  /// Calculates the volume that should be applied at a given date
  /// - Parameter date: The date to calculate volume for
  /// - Returns: The volume level (0.0 to 1.0) that should be applied at this date
  public func volumeAtDate(_ date: Date) -> Float {
    // If the date is before the spin starts, return starting volume
    if date < airtime {
      return startingVolume
    }

    // Calculate milliseconds since spin start
    let timeInterval = date.timeIntervalSince(airtime)
    let milliseconds = Int(timeInterval * 1000)

    return volumeAtMS(milliseconds)
  }

  /// Creates a new Spin with the airtime adjusted by the given offset.
  /// All other properties remain unchanged from the original spin.
  ///
  /// - Parameter offset: The time interval to add to the airtime (positive for future, negative for past)
  /// - Returns: A new Spin instance with adjusted airtime
  public func withOffset(_ offset: TimeInterval) -> Spin {
    var newSpin = Spin(
      id: id,
      stationId: stationId,
      airtime: airtime.addingTimeInterval(offset),
      startingVolume: startingVolume,
      createdAt: createdAt,
      updatedAt: updatedAt,
      audioBlock: audioBlock,
      fades: fades,
      relatedTexts: relatedTexts
    )

    // Preserve the dateProvider
    newSpin.dateProvider = dateProvider

    return newSpin
  }

  private enum CodingKeys: String, CodingKey {
    case id, stationId, airtime, createdAt, updatedAt, audioBlock, fades, startingVolume,
      relatedTexts
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
    let decodedFades = try container.decode([Fade].self, forKey: .fades)
    fades = decodedFades.sorted { $0.atMS < $1.atMS }
    relatedTexts = try container.decodeIfPresent([RelatedText].self, forKey: .relatedTexts)

    // Initialize dateProvider with default value
    dateProvider = DateProvider()
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
    dateProvider: DateProviderProtocol? = nil
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

extension Spin: Equatable, Hashable, Identifiable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(audioBlock)
    hasher.combine(airtime)
  }

  public static func == (lhs: Spin, rhs: Spin) -> Bool {
    return lhs.id == rhs.id && lhs.audioBlock == rhs.audioBlock && lhs.airtime == rhs.airtime
  }
}
