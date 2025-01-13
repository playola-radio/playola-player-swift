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
}
