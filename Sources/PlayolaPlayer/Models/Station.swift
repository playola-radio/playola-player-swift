//
//  Station.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/9/25.
//
import Foundation

struct Station: Codable, Sendable {
  let id: String
  let name: String
  let curatorName: String
  let imageUrl: String
  let createdAt: Date
  let updatedAt: Date

  public init(id: String, name: String, curatorName: String, imageUrl: String, createdAt: Date, updatedAt: Date) {
    self.id = id
    self.name = name
    self.curatorName = curatorName
    self.imageUrl = imageUrl
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
