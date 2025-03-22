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

// Extension to provide additional mock utilities for AudioBlock
extension AudioBlock {
    /// Creates a mock AudioBlock with optional property overrides
    /// - Parameters:
    ///   - id: Optional override for audio block ID
    ///   - title: Optional override for title
    ///   - artist: Optional override for artist
    ///   - album: Optional override for album
    ///   - durationMS: Optional override for duration in milliseconds
    ///   - endOfMessageMS: Optional override for end of message in milliseconds
    ///   - beginningOfOutroMS: Optional override for beginning of outro in milliseconds
    ///   - endOfIntroMS: Optional override for end of intro in milliseconds
    ///   - lengthOfOutroMS: Optional override for length of outro in milliseconds
    ///   - type: Optional override for type
    ///   - downloadUrl: Optional override for download URL
    ///   - s3Key: Optional override for S3 key
    ///   - s3BucketName: Optional override for S3 bucket name
    ///   - popularity: Optional override for popularity
    ///   - imageUrl: Optional override for image URL
    ///   - createdAt: Optional override for created date
    ///   - updatedAt: Optional override for updated date
    /// - Returns: A mock AudioBlock with specified overrides
    static func mockWith(
        id: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        durationMS: Int? = nil,
        endOfMessageMS: Int? = nil,
        beginningOfOutroMS: Int? = nil,
        endOfIntroMS: Int? = nil,
        lengthOfOutroMS: Int? = nil,
        type: String? = nil,
        downloadUrl: String? = nil,
        s3Key: String? = nil,
        s3BucketName: String? = nil,
        popularity: Int? = nil,
        imageUrl: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> AudioBlock {
        // Start with the default mock
        let mockBlock = AudioBlock.mock

        // Create new audio block with overrides
        return AudioBlock(
            id: id ?? mockBlock.id,
            title: title ?? mockBlock.title,
            artist: artist ?? mockBlock.artist,
            durationMS: durationMS ?? mockBlock.durationMS,
            endOfMessageMS: endOfMessageMS ?? mockBlock.endOfMessageMS,
            beginningOfOutroMS: beginningOfOutroMS ?? mockBlock.beginningOfOutroMS,
            endOfIntroMS: endOfIntroMS ?? mockBlock.endOfIntroMS,
            lengthOfOutroMS: lengthOfOutroMS ?? mockBlock.lengthOfOutroMS,
            downloadUrl: downloadUrl ?? mockBlock.downloadUrl,
            s3Key: s3Key ?? mockBlock.s3Key,
            s3BucketName: s3BucketName ?? mockBlock.s3BucketName,
            type: type ?? mockBlock.type,
            createdAt: createdAt ?? mockBlock.createdAt,
            updatedAt: updatedAt ?? mockBlock.updatedAt,
            album: album ?? mockBlock.album,
            popularity: popularity ?? mockBlock.popularity,
            youTubeId: mockBlock.youTubeId,
            isrc: mockBlock.isrc,
            spotifyId: mockBlock.spotifyId,
            imageUrl: imageUrl ?? mockBlock.imageUrl
        )
    }
}
