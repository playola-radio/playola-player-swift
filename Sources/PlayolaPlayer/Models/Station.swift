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
  public let imageUrl: String
  public let createdAt: Date
  public let updatedAt: Date

  public init(id: String, name: String, curatorName: String, imageUrl: String, createdAt: Date, updatedAt: Date) {
    self.id = id
    self.name = name
    self.curatorName = curatorName
    self.imageUrl = imageUrl
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
