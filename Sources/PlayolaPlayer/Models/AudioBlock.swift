//
//  AudioBlock.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public struct AudioBlock: Codable, Sendable {
  public let id: String
  public let title: String
  public let artist: String
  public let durationMS: Int
  public let endOfMessageMS: Int
  public let beginningOfOutroMS: Int
  public let endOfIntroMS: Int
  public let lengthOfOutroMS: Int
  public let downloadUrl: String
  public let s3Key: String
  public let s3BucketName: String
  public let type: String
  public let createdAt: Date
  public let updatedAt: Date
  public let album: String?
  public let popularity: Int?
  public let youTubeId: Int?
  public let isrc: String?
  public let spotifyId: String?
  public let imageUrl: String?
}

extension AudioBlock {
  public static var mocks: [AudioBlock] {
    return Schedule.mock.spins.map { $0.audioBlock! }
  }

  public static var mock: AudioBlock { .mocks[0] }
}
