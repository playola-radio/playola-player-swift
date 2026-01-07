//
//  ScheduledShow.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/26.
//

import Foundation

/// Represents a scheduled instance of a show
public struct ScheduledShow: Codable, Sendable, Equatable, Hashable, Identifiable {
  public let id: String
  public let showId: String
  public let stationId: String
  public let airtime: Date
  public let createdAt: Date
  public let updatedAt: Date
  public let show: Show?

  public init(
    id: String,
    showId: String,
    stationId: String,
    airtime: Date,
    createdAt: Date,
    updatedAt: Date,
    show: Show?
  ) {
    self.id = id
    self.showId = showId
    self.stationId = stationId
    self.airtime = airtime
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.show = show
  }
}

extension ScheduledShow {
  public static var mock: ScheduledShow {
    ScheduledShow(
      id: "mock-scheduled-show-id",
      showId: "mock-show-id",
      stationId: "mock-station-id",
      airtime: Date(timeIntervalSince1970: 1_800_000_000),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      show: .mock
    )
  }

  public static func mockWith(
    id: String? = nil,
    showId: String? = nil,
    stationId: String? = nil,
    airtime: Date? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    show: Show? = nil
  ) -> ScheduledShow {
    let mock = Self.mock
    return ScheduledShow(
      id: id ?? mock.id,
      showId: showId ?? mock.showId,
      stationId: stationId ?? mock.stationId,
      airtime: airtime ?? mock.airtime,
      createdAt: createdAt ?? mock.createdAt,
      updatedAt: updatedAt ?? mock.updatedAt,
      show: show ?? mock.show
    )
  }
}
