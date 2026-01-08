//
//  Station.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/9/25.
//
import Foundation

public struct Station: Codable, Sendable {
  public let id: String
  public let name: String
  public let curatorName: String
  public let imageUrl: URL?
  public let description: String
  public let active: Bool?
  public let releaseDate: Date?
  public let createdAt: Date
  public let updatedAt: Date

  // Custom coding keys to handle the imageUrl conversion
  private enum CodingKeys: String, CodingKey {
    case id, name, curatorName, description, active, releaseDate, createdAt, updatedAt
    case imageUrlString = "imageUrl"
  }
  private static let releaseDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    curatorName = try container.decode(String.self, forKey: .curatorName)
    description = try container.decode(String.self, forKey: .description)
    active = try container.decodeIfPresent(Bool.self, forKey: .active)
    if let releaseDateString = try container.decodeIfPresent(String.self, forKey: .releaseDate) {
      if let parsed = DateFormatter.iso8601Full.date(from: releaseDateString) {
        releaseDate = parsed
      } else if let dateOnly = Station.releaseDateFormatter.date(from: releaseDateString) {
        releaseDate = dateOnly
      } else {
        releaseDate = nil
      }
    } else {
      releaseDate = nil
    }
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)

    // Convert imageUrl string to URL if possible
    if let imageUrlString = try container.decodeIfPresent(String.self, forKey: .imageUrlString) {
      imageUrl = URL(string: imageUrlString)
    } else {
      imageUrl = nil
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(curatorName, forKey: .curatorName)
    try container.encode(description, forKey: .description)
    try container.encodeIfPresent(active, forKey: .active)
    if let releaseDate {
      let encodedDate = DateFormatter.iso8601Full.string(from: releaseDate)
      try container.encode(encodedDate, forKey: .releaseDate)
    }
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)

    // Convert URL back to string for encoding
    try container.encodeIfPresent(imageUrl?.absoluteString, forKey: .imageUrlString)
  }

  // Original initializer updated to convert String to URL
  public init(
    id: String, name: String, curatorName: String, imageUrl: String?, description: String,
    active: Bool? = nil, releaseDate: Date? = nil, createdAt: Date, updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.curatorName = curatorName
    self.imageUrl = imageUrl != nil ? URL(string: imageUrl!) : nil
    self.description = description
    self.active = active
    self.releaseDate = releaseDate
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  // New convenience initializer that accepts URL directly
  public init(
    id: String, name: String, curatorName: String, imageUrl: URL?, description: String,
    active: Bool? = nil, releaseDate: Date? = nil, createdAt: Date, updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.curatorName = curatorName
    self.imageUrl = imageUrl
    self.description = description
    self.active = active
    self.releaseDate = releaseDate
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

extension Station: Hashable, Equatable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  public static func == (lhs: Station, rhs: Station) -> Bool {
    return lhs.id == rhs.id
  }
}

extension Station {
  public static var mock: Station {
    Station(
      id: "mock-station-id",
      name: "Mock Station",
      curatorName: "Mock Curator",
      imageUrl: nil as URL?,
      description: "A mock station for testing",
      active: true,
      releaseDate: nil,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }

  public static func mockWith(
    id: String = "mock-station-id",
    name: String = "Mock Station",
    curatorName: String = "Mock Curator",
    imageUrl: URL? = nil,
    description: String = "A mock station for testing",
    active: Bool? = true,
    releaseDate: Date? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) -> Station {
    Station(
      id: id,
      name: name,
      curatorName: curatorName,
      imageUrl: imageUrl,
      description: description,
      active: active,
      releaseDate: releaseDate,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
