//  SessionSeamInvariantTests.swift
//  PlayolaPlayer
//
// Structural guard: the SDK is host-session-owned — it must NEVER touch the
// process-global AVAudioSession. No source file may reference
// AVAudioSession.sharedInstance, .setCategory(, or .setActive(. The host app
// owns session configuration, activation, and interruption/route policy.

import Foundation
import Testing

struct SessionSeamInvariantTests {
  @Test("No SDK source touches the process-global AVAudioSession")
  func sdkNeverTouchesSharedSession() throws {
    let thisFile = URL(fileURLWithPath: #filePath)
    let repoRoot =
      thisFile  // Tests/PlayolaPlayerTests/<file> -> repo root
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sourcesDir = repoRoot.appendingPathComponent("Sources")
    // #filePath is compile-time: on runners that execute a binary built
    // elsewhere (Xcode Cloud, device farms) the sources won't exist. Skip
    // gracefully there — the invariant is enforced wherever sources are local.
    guard FileManager.default.fileExists(atPath: sourcesDir.path) else { return }
    guard
      let enumerator = FileManager.default.enumerator(
        at: sourcesDir, includingPropertiesForKeys: nil)
    else {
      Issue.record("Sources directory not found at \(sourcesDir.path)")
      return
    }
    var offenders: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let content = try String(contentsOf: url, encoding: .utf8)
      // Direct access AND the two session-mutating verbs (catches alias/wrapper
      // bypass). Substring match: a comment mentioning ".setCategory(" would
      // false-positive — acceptable; the failure message names the file.
      // Also catch direct construction (`AVAudioSession(`) so the new sample-buffer render path
      // (Phase 5) can't smuggle in a private session — it needs none; that is what lets it route
      // AirPlay-2 long-form (host owns the session).
      for needle in [
        "AVAudioSession.sharedInstance", "AVAudioSession(", ".setCategory(", ".setActive(",
      ]
      where content.contains(needle) {
        offenders.append("\(url.lastPathComponent): \(needle)")
      }
    }
    #expect(offenders.isEmpty, "SDK must not touch AVAudioSession: \(offenders)")
  }
}
