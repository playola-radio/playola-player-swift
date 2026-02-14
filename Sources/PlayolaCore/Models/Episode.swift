//
//  Episode.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/7/26.
//

import Foundation

/// Represents an episode of a show
public struct Episode: Codable, Sendable, Equatable, Hashable, Identifiable {
  public let id: String
  public let showId: String
  public let title: String
  public let durationMS: Int?
  public let createdAt: Date
  public let updatedAt: Date
  public let show: Show?

  public init(
    id: String,
    showId: String,
    title: String,
    durationMS: Int? = nil,
    createdAt: Date,
    updatedAt: Date,
    show: Show? = nil
  ) {
    self.id = id
    self.showId = showId
    self.title = title
    self.durationMS = durationMS
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.show = show
  }
}

extension Episode {
  public static var mock: Episode {
    Episode(
      id: "mock-episode-id",
      showId: "mock-show-id",
      title: "Mock Episode Title",
      durationMS: 1000 * 60 * 30,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      show: .mock
    )
  }

  public static func mockWith(
    id: String? = nil,
    showId: String? = nil,
    title: String? = nil,
    durationMS: Int?? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    show: Show?? = nil
  ) -> Episode {
    let mock = Self.mock
    return Episode(
      id: id ?? mock.id,
      showId: showId ?? mock.showId,
      title: title ?? mock.title,
      durationMS: durationMS ?? mock.durationMS,
      createdAt: createdAt ?? mock.createdAt,
      updatedAt: updatedAt ?? mock.updatedAt,
      show: show ?? mock.show
    )
  }
}
