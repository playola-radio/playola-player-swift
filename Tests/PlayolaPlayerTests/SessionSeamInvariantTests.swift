//  SessionSeamInvariantTests.swift
//  PlayolaPlayer
//
// Structural guard: the ONLY file in the SDK allowed to reference
// AVAudioSession.sharedInstance is AudioSessionManager.swift. This is what makes
// "swap the manager" equivalent to "SDK never touches the session".

import Foundation
import Testing

struct SessionSeamInvariantTests {
  @Test
  func onlyAudioSessionManagerTouchesSharedSession() throws {
    let thisFile = URL(fileURLWithPath: #filePath)
    let repoRoot =
      thisFile  // Tests/PlayolaPlayerTests/<file> -> repo root
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sourcesDir = repoRoot.appendingPathComponent("Sources")
    let enumerator = FileManager.default.enumerator(
      at: sourcesDir, includingPropertiesForKeys: nil)!
    var offenders: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      guard url.lastPathComponent != "AudioSessionManager.swift" else { continue }
      let content = try String(contentsOf: url, encoding: .utf8)
      // Direct access AND the two session-mutating verbs (catches alias/wrapper bypass).
      for needle in ["AVAudioSession.sharedInstance", ".setCategory(", ".setActive("] {
        if content.contains(needle) {
          offenders.append("\(url.lastPathComponent): \(needle)")
        }
      }
    }
    #expect(offenders.isEmpty, "Direct session access outside the seam: \(offenders)")
  }
}
