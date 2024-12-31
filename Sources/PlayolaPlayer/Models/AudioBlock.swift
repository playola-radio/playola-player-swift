//
//  AudioBlock.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public struct AudioBlock: Codable, Sendable {
  let id: String
  let title: String
  let artist: String
  let durationMS: Int
  let endOfMessageMS: Int
  let beginningOfOutroMS: Int
  let endOfIntroMS: Int
  let lengthOfOutroMS: Int
  let downloadUrl: String
  let s3Key: String
  let s3BucketName: String
  let type: String
  let createdAt: Date
  let updatedAt: Date
  let album: String?
  let popularity: Int?
  let youTubeId: Int?
  let isrc: String?
  let spotifyId: String?
  let imageUrl: String?
}

extension AudioBlock {
  public static var mocks: [AudioBlock] {
    return Schedule.mock.spins.map { $0.audioBlock! }
  }

  public static var mock: AudioBlock { .mocks[0] }
}
