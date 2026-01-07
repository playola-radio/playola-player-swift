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

  public init(
    id: String,
    episodeId: String,
    stationId: String,
    airtime: Date,
    createdAt: Date,
    updatedAt: Date,
    episode: Episode? = nil
  ) {
    self.id = id
    self.episodeId = episodeId
    self.stationId = stationId
    self.airtime = airtime
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.episode = episode
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
      episode: .mock
    )
  }

  public static func mockWith(
    id: String? = nil,
    episodeId: String? = nil,
    stationId: String? = nil,
    airtime: Date? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    episode: Episode?? = nil
  ) -> Airing {
    let mock = Self.mock
    return Airing(
      id: id ?? mock.id,
      episodeId: episodeId ?? mock.episodeId,
      stationId: stationId ?? mock.stationId,
      airtime: airtime ?? mock.airtime,
      createdAt: createdAt ?? mock.createdAt,
      updatedAt: updatedAt ?? mock.updatedAt,
      episode: episode ?? mock.episode
    )
  }
}
