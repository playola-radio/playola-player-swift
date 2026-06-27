//
//  Airing.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/7/26.
//

import Foundation

/// Represents a scheduled airing of an episode
public struct Airing: Codable, Sendable, Equatable, Hashable, Identifiable {
  public let id: String
  public let episodeId: String
  public let stationId: String
  public let airtime: Date
  public let createdAt: Date
  public let updatedAt: Date
  public let episode: Episode?
  public let station: Station?

  /// The real moment the show goes on air (`MIN(spin.airtime)` across the airing's spins).
  ///
  /// Accounts for the "lead gap" where preceding content pushes the show later than its
  /// nominal `airtime` slot. Present only on airings sourced from the schedule feed;
  /// `nil` for airings sourced elsewhere.
  public let startTime: Date?

  /// The real moment the show goes off air (`MAX(spin.endOfMessageTime)`, floored at
  /// `airtime + episode.durationMS`).
  ///
  /// Present only on airings sourced from the schedule feed; `nil` for airings sourced
  /// elsewhere.
  public let endTime: Date?

  public init(
    id: String,
    episodeId: String,
    stationId: String,
    airtime: Date,
    createdAt: Date,
    updatedAt: Date,
    episode: Episode? = nil,
    station: Station? = nil,
    startTime: Date? = nil,
    endTime: Date? = nil
  ) {
    self.id = id
    self.episodeId = episodeId
    self.stationId = stationId
    self.airtime = airtime
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.episode = episode
    self.station = station
    self.startTime = startTime
    self.endTime = endTime
  }
}

extension Airing {
  public static var mock: Airing {
    Airing(
      id: "mock-airing-id",
      episodeId: "mock-episode-id",
      stationId: "mock-station-id",
      airtime: Date(timeIntervalSince1970: 1_800_000_000),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      episode: .mock,
      station: .mock
    )
  }

  public static func mockWith(
    id: String? = nil,
    episodeId: String? = nil,
    stationId: String? = nil,
    airtime: Date? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    episode: Episode?? = nil,
    station: Station?? = nil
  ) -> Airing {
    let mock = Self.mock
    return Airing(
      id: id ?? mock.id,
      episodeId: episodeId ?? mock.episodeId,
      stationId: stationId ?? mock.stationId,
      airtime: airtime ?? mock.airtime,
      createdAt: createdAt ?? mock.createdAt,
      updatedAt: updatedAt ?? mock.updatedAt,
      episode: episode ?? mock.episode,
      station: station ?? mock.station
    )
  }
}
