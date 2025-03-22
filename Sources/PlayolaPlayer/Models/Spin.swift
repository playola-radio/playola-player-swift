//
//  Spin.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public struct Fade: Codable, Sendable {
  let atMS: Int
  let toVolume: Float
}

public struct Spin: Codable, Sendable {
  let id: String
  let stationId: String
  let airtime: Date
  let startingVolume: Float
  let createdAt: Date
  let updatedAt: Date
  let audioBlock: AudioBlock?
  let fades: [Fade]

  // dependency injection
  var dateProvider: DateProvider! = .shared

  var endtime: Date {
    return airtime + TimeInterval(Double(audioBlock?.endOfMessageMS ?? 0) / 1000)
  }

  var isPlaying: Bool {
    return airtime <= dateProvider.now() &&
          dateProvider.now() <= endtime
  }

  private enum CodingKeys: String, CodingKey {
    case id, stationId, airtime, createdAt, updatedAt, audioBlock, fades, startingVolume
  }
}


extension Spin: Equatable {
  public static func ==(lhs: Spin, rhs: Spin) -> Bool {
    return lhs.id == rhs.id &&
    lhs.audioBlock?.id == rhs.audioBlock?.id &&
    lhs.airtime == rhs.airtime
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
    ///   - dateProvider: Optional override for date provider
    /// - Returns: A mock Spin with specified overrides
    static func mockWith(
        id: String? = nil,
        airtime: Date? = nil,
        stationId: String? = nil,
        audioBlock: AudioBlock? = nil,
        startingVolume: Float? = nil,
        fades: [Fade]? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
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
            fades: fades ?? mockSpin.fades
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
