import Foundation

/// Represents an audio content item to be played.
///
/// An `AudioBlock` contains all metadata and content information needed to play
/// audio content, including:
/// - Basic metadata (title, artist, etc.)
/// - Timing information for intros, outros, and message end points
/// - Location information to retrieve the audio file
public struct AudioBlock: Codable, Sendable {
  /// Unique identifier for this audio block
  public let id: String

  /// Title of the audio content (song title, ad title, etc.)
  public let title: String

  /// Artist name for the audio content
  public let artist: String

  /// Total duration of the audio in milliseconds
  public let durationMS: Int

  /// Timestamp in milliseconds when the main message/content ends
  /// This is used to determine when the next content can begin
  public let endOfMessageMS: Int

  /// Timestamp in milliseconds when the outro section begins
  /// This marks where another audio block could start crossfading in
  public let beginningOfOutroMS: Int

  /// Timestamp in milliseconds when the intro section ends
  public let endOfIntroMS: Int

  /// Duration of the outro section in milliseconds
  public let lengthOfOutroMS: Int

  /// URL where the audio file can be downloaded
  public let downloadUrl: URL?

  /// Storage key in the S3 bucket
  public let s3Key: String

  /// Name of the S3 bucket containing the audio file
  public let s3BucketName: String

  /// Type of audio block (song, commercialblock, audioimage, etc.)
  public let type: String
  public let createdAt: Date
  public let updatedAt: Date
  public let album: String?
  public let popularity: Int?
  public let youTubeId: Int?
  public let isrc: String?
  public let spotifyId: String?
  public let imageUrl: URL?

  // Custom coding keys to handle the imageUrl conversion
  private enum CodingKeys: String, CodingKey {
    case id, title, artist, durationMS, endOfMessageMS, beginningOfOutroMS, endOfIntroMS
    case lengthOfOutroMS, s3Key, s3BucketName, type, createdAt, updatedAt
    case album, popularity, youTubeId, isrc, spotifyId
    case imageUrlString = "imageUrl"
    case downloadUrlString = "downloadUrl"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    artist = try container.decode(String.self, forKey: .artist)
    durationMS = try container.decode(Int.self, forKey: .durationMS)
    endOfMessageMS = try container.decode(Int.self, forKey: .endOfMessageMS)
    beginningOfOutroMS = try container.decode(Int.self, forKey: .beginningOfOutroMS)
    endOfIntroMS = try container.decode(Int.self, forKey: .endOfIntroMS)
    lengthOfOutroMS = try container.decode(Int.self, forKey: .lengthOfOutroMS)
    s3Key = try container.decode(String.self, forKey: .s3Key)
    s3BucketName = try container.decode(String.self, forKey: .s3BucketName)
    type = try container.decode(String.self, forKey: .type)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    album = try container.decodeIfPresent(String.self, forKey: .album)
    popularity = try container.decodeIfPresent(Int.self, forKey: .popularity)
    youTubeId = try container.decodeIfPresent(Int.self, forKey: .youTubeId)
    isrc = try container.decodeIfPresent(String.self, forKey: .isrc)
    spotifyId = try container.decodeIfPresent(String.self, forKey: .spotifyId)

    // Convert imageUrl string to URL
    if let imageUrlString = try container.decodeIfPresent(String.self, forKey: .imageUrlString) {
      imageUrl = URL(string: imageUrlString)
    } else {
      imageUrl = nil
    }

    if let downloadUrlString = try container.decodeIfPresent(String.self, forKey: .downloadUrlString) {
      downloadUrl = URL(string: downloadUrlString)
    } else {
      downloadUrl = nil
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(artist, forKey: .artist)
    try container.encode(durationMS, forKey: .durationMS)
    try container.encode(endOfMessageMS, forKey: .endOfMessageMS)
    try container.encode(beginningOfOutroMS, forKey: .beginningOfOutroMS)
    try container.encode(endOfIntroMS, forKey: .endOfIntroMS)
    try container.encode(lengthOfOutroMS, forKey: .lengthOfOutroMS)
    try container.encode(s3Key, forKey: .s3Key)
    try container.encode(s3BucketName, forKey: .s3BucketName)
    try container.encode(type, forKey: .type)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encodeIfPresent(album, forKey: .album)
    try container.encodeIfPresent(popularity, forKey: .popularity)
    try container.encodeIfPresent(youTubeId, forKey: .youTubeId)
    try container.encodeIfPresent(isrc, forKey: .isrc)
    try container.encodeIfPresent(spotifyId, forKey: .spotifyId)

    // Convert URL back to string for encoding
    try container.encodeIfPresent(imageUrl?.absoluteString, forKey: .imageUrlString)
    try container.encodeIfPresent(downloadUrl?.absoluteString, forKey: .downloadUrlString)
  }

  public init(id: String, title: String, artist: String, durationMS: Int, endOfMessageMS: Int, beginningOfOutroMS: Int, endOfIntroMS: Int, lengthOfOutroMS: Int, downloadUrl: URL?, s3Key: String, s3BucketName: String, type: String, createdAt: Date, updatedAt: Date, album: String?, popularity: Int?, youTubeId: Int?, isrc: String?, spotifyId: String?, imageUrl: String?) {
    self.id = id
    self.title = title
    self.artist = artist
    self.durationMS = durationMS
    self.endOfMessageMS = endOfMessageMS
    self.beginningOfOutroMS = beginningOfOutroMS
    self.endOfIntroMS = endOfIntroMS
    self.lengthOfOutroMS = lengthOfOutroMS
    self.downloadUrl = downloadUrl
    self.s3Key = s3Key
    self.s3BucketName = s3BucketName
    self.type = type
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.album = album
    self.popularity = popularity
    self.youTubeId = youTubeId
    self.isrc = isrc
    self.spotifyId = spotifyId
    self.imageUrl = imageUrl != nil ? URL(string: imageUrl!) : nil
  }

  // Additional convenience initializer for URL
  public init(id: String, title: String, artist: String, durationMS: Int, endOfMessageMS: Int, beginningOfOutroMS: Int, endOfIntroMS: Int, lengthOfOutroMS: Int, downloadUrl: URL?, s3Key: String, s3BucketName: String, type: String, createdAt: Date, updatedAt: Date, album: String?, popularity: Int?, youTubeId: Int?, isrc: String?, spotifyId: String?, imageUrl: URL?) {
    self.id = id
    self.title = title
    self.artist = artist
    self.durationMS = durationMS
    self.endOfMessageMS = endOfMessageMS
    self.beginningOfOutroMS = beginningOfOutroMS
    self.endOfIntroMS = endOfIntroMS
    self.lengthOfOutroMS = lengthOfOutroMS
    self.downloadUrl = downloadUrl
    self.s3Key = s3Key
    self.s3BucketName = s3BucketName
    self.type = type
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.album = album
    self.popularity = popularity
    self.youTubeId = youTubeId
    self.isrc = isrc
    self.spotifyId = spotifyId
    self.imageUrl = imageUrl
  }
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
  public static func mockWith(
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
    downloadUrl: URL? = nil,
    s3Key: String? = nil,
    s3BucketName: String? = nil,
    popularity: Int? = nil,
    imageUrl: URL? = nil,
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
