//
//  Show.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/26.
//

import Foundation

/// Represents a radio show
public struct Show: Codable, Sendable, Equatable, Hashable, Identifiable {
  public let id: String
  public let stationId: String
  public let title: String
  public let rrule: String?
  public let durationMS: Int?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: String,
    stationId: String,
    title: String,
    rrule: String? = nil,
    durationMS: Int? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.stationId = stationId
    self.title = title
    self.rrule = rrule
    self.durationMS = durationMS
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

extension Show {
  public static var mock: Show {
    Show(
      id: "mock-show-id",
      stationId: "mock-station-id",
      title: "Mock Show Title",
      rrule: nil,
      durationMS: 1000 * 60 * 30,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }

  public static func mockWith(
    id: String? = nil,
    stationId: String? = nil,
    title: String? = nil,
    rrule: String?? = nil,
    durationMS: Int?? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) -> Show {
    let mock = Self.mock
    return Show(
      id: id ?? mock.id,
      stationId: stationId ?? mock.stationId,
      title: title ?? mock.title,
      rrule: rrule ?? mock.rrule,
      durationMS: durationMS ?? mock.durationMS,
      createdAt: createdAt ?? mock.createdAt,
      updatedAt: updatedAt ?? mock.updatedAt
    )
  }
}
