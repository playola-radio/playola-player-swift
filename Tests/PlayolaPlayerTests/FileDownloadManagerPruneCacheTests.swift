//  FileDownloadManagerPruneCacheTests.swift
//  PlayolaPlayer
//
// Covers pruneCache(maxSize:excludeFilepaths:) — active-file exclusions must survive pruning,
// their size still counts toward pressure accounting, path-form differences can't defeat an
// exclusion, and deletion failures must propagate instead of being silently swallowed.

import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct FileDownloadManagerPruneCacheTests {
  private func makeManager() throws -> (manager: FileDownloadManagerAsync, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FileDownloadManagerPruneCacheTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (FileDownloadManagerAsync(cacheDirectoryOverride: dir), dir)
  }

  @discardableResult
  private func writeFile(
    named name: String, sizeBytes: Int, createdAt date: Date, in dir: URL
  ) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 0x1, count: sizeBytes).write(to: url)
    try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    return url
  }

  @Test("excluded active file survives prune under pressure")
  func excludedActiveFileSurvivesPruneUnderPressure() async throws {
    let (manager, dir) = try makeManager()
    let now = Date()
    let excludedURL = try writeFile(
      named: "excluded-oldest.mp3", sizeBytes: 40, createdAt: now.addingTimeInterval(-300),
      in: dir)
    try writeFile(
      named: "middle.mp3", sizeBytes: 40, createdAt: now.addingTimeInterval(-200), in: dir)
    try writeFile(
      named: "newest.mp3", sizeBytes: 40, createdAt: now.addingTimeInterval(-100), in: dir)

    try await manager.pruneCache(maxSize: 80, excludeFilepaths: [excludedURL.path])

    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    #expect(remaining.contains("excluded-oldest.mp3"))
    #expect(!remaining.contains("middle.mp3"))
    #expect(remaining.contains("newest.mp3"))
  }

  @Test("non-excluded files are deleted oldest-first and the size target is met")
  func nonExcludedFilesDeletedOldestFirstAndSizeTargetMet() async throws {
    let (manager, dir) = try makeManager()
    let now = Date()
    try writeFile(
      named: "oldest.mp3", sizeBytes: 60, createdAt: now.addingTimeInterval(-200), in: dir)
    try writeFile(
      named: "newest.mp3", sizeBytes: 60, createdAt: now.addingTimeInterval(-100), in: dir)

    try await manager.pruneCache(maxSize: 60, excludeFilepaths: [])

    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    #expect(!remaining.contains("oldest.mp3"))
    #expect(remaining.contains("newest.mp3"))

    let finalSize = try remaining.reduce(Int64(0)) { total, name in
      let attrs = try FileManager.default.attributesOfItem(
        atPath: dir.appendingPathComponent(name).path)
      return total + Int64(attrs[.size] as? Int ?? 0)
    }
    #expect(finalSize <= 60)
  }

  @Test("exclusion survives non-standardized path form differences")
  func exclusionSurvivesPathFormDifferences() async throws {
    let (manager, dir) = try makeManager()
    let now = Date()
    let excludedURL = try writeFile(
      named: "excluded.mp3", sizeBytes: 40, createdAt: now.addingTimeInterval(-300), in: dir)
    try writeFile(
      named: "newer.mp3", sizeBytes: 40, createdAt: now.addingTimeInterval(-100), in: dir)

    let nonStandardizedPath = dir.path + "/./excluded.mp3"
    #expect(nonStandardizedPath != excludedURL.path)

    try await manager.pruneCache(maxSize: 40, excludeFilepaths: [nonStandardizedPath])

    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    #expect(remaining.contains("excluded.mp3"))
    #expect(!remaining.contains("newer.mp3"))
  }

  @Test("a deletion failure propagates to the caller instead of being swallowed")
  func deletionFailurePropagatesToCaller() async throws {
    let (manager, dir) = try makeManager()
    let now = Date()
    try writeFile(named: "a.mp3", sizeBytes: 40, createdAt: now.addingTimeInterval(-200), in: dir)
    try writeFile(named: "b.mp3", sizeBytes: 40, createdAt: now.addingTimeInterval(-100), in: dir)

    // Removing write permission on the containing directory makes removeItem(at:) fail even
    // though the files themselves remain readable.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    await #expect(throws: (any Error).self) {
      try await manager.pruneCache(maxSize: 40, excludeFilepaths: [])
    }
  }
}
