//  SessionSeamInvariantTests.swift
//  PlayolaPlayer
//
// Structural guard: the ONLY file in the SDK allowed to reference
// AVAudioSession.sharedInstance is AudioSessionManager.swift. This is what makes
// "swap the manager" equivalent to "SDK never touches the session".

import Foundation
import Testing

struct SessionSeamInvariantTests {
  @Test("Only AudioSessionManager.swift references AVAudioSession session-mutating APIs")
  func onlyAudioSessionManagerTouchesSharedSession() throws {
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
      guard url.lastPathComponent != "AudioSessionManager.swift" else { continue }
      let content = try String(contentsOf: url, encoding: .utf8)
      // Direct access AND the two session-mutating verbs (catches alias/wrapper
      // bypass). Substring match: a comment mentioning ".setCategory(" would
      // false-positive — acceptable; the failure message names the file.
      for needle in ["AVAudioSession.sharedInstance", ".setCategory(", ".setActive("]
      where content.contains(needle) {
        offenders.append("\(url.lastPathComponent): \(needle)")
      }
    }
    #expect(offenders.isEmpty, "Direct session access outside the seam: \(offenders)")
  }
}
