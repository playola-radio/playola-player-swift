//  TransportInvariantTests.swift
//  PlayolaPlayer
//
// Structural + behavioral guard for the HTTP/3-preferring transport.
//
// 1. No SDK source may cap TLS (the old `.TLSv12` mitigation). Capping is still
//    TCP and never helped the `http3Rescues` networks; reintroducing it would
//    silently break the fix.
// 2. `PlayolaTransport` must mark API requests HTTP/3-preferring and must NOT
//    mark S3 download configs as capped.

import Foundation
import Testing

@testable import PlayolaPlayer

struct TransportInvariantTests {
  @Test("No SDK source caps TLS to 1.2")
  func sdkNeverCapsTLS() throws {
    let thisFile = URL(fileURLWithPath: #filePath)
    let repoRoot =
      thisFile  // Tests/PlayolaPlayerTests/<file> -> repo root
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sourcesDir = repoRoot.appendingPathComponent("Sources")
    // #filePath is compile-time: on runners that execute a binary built
    // elsewhere the sources won't exist. Skip gracefully there.
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
      for needle in [
        "tlsMaximumSupportedProtocolVersion = .TLSv12",
        "tlsMaximumSupportedProtocolVersion = .TLSv1",
      ] where content.contains(needle) {
        offenders.append("\(url.lastPathComponent): \(needle)")
      }
    }
    #expect(offenders.isEmpty, "SDK must not cap TLS (breaks http3Rescues networks): \(offenders)")
  }

  @Test("API requests prefer HTTP/3")
  func apiRequestPrefersHTTP3() {
    let url = URL(string: "https://admin-api.playola.fm/v1/stations/x/schedule")!
    let request = PlayolaTransport.apiRequest(url: url)
    #expect(request.assumesHTTP3Capable == true)
  }

  @Test("preferHTTP3 sets the flag on an existing request")
  func preferHTTP3MutatesRequest() {
    var request = URLRequest(url: URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!)
    #expect(request.assumesHTTP3Capable == false)
    PlayolaTransport.preferHTTP3(&request)
    #expect(request.assumesHTTP3Capable == true)
  }

  @Test("Download configuration is uncapped and not HTTP/3")
  func downloadConfigurationIsUncapped() {
    let config = PlayolaTransport.makeDownloadConfiguration()
    // Default (uncapped) leaves the min/max at the framework defaults (0), not a
    // pinned TLS 1.2 ceiling.
    #expect(config.tlsMaximumSupportedProtocolVersion != .TLSv12)
  }
}
