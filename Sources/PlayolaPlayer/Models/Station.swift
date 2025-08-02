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
  public let createdAt: Date
  public let updatedAt: Date

  // Custom coding keys to handle the imageUrl conversion
  private enum CodingKeys: String, CodingKey {
    case id, name, curatorName, createdAt, updatedAt
    case imageUrlString = "imageUrl"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    curatorName = try container.decode(String.self, forKey: .curatorName)
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
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)

    // Convert URL back to string for encoding
    try container.encodeIfPresent(imageUrl?.absoluteString, forKey: .imageUrlString)
  }

  // Original initializer updated to convert String to URL
  public init(
    id: String, name: String, curatorName: String, imageUrl: String?, createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.curatorName = curatorName
    self.imageUrl = imageUrl != nil ? URL(string: imageUrl!) : nil
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  // New convenience initializer that accepts URL directly
  public init(
    id: String, name: String, curatorName: String, imageUrl: URL?, createdAt: Date, updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.curatorName = curatorName
    self.imageUrl = imageUrl
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
