import Foundation
import Testing

@testable import PlayolaPlayer

@MainActor
struct PlayolaStationPlayerTests {
  @Test("Configure passes custom baseURL to ListeningSessionReporter")
  func testConfigurePassesBaseURL() async throws {
    let customBaseURL = URL(string: "http://localhost:5000")!
    let mockAuthProvider = MockAuthProvider()
    let mockFileDownloadManager = MockFileDownloadManager()
    let player = PlayolaStationPlayer(fileDownloadManager: mockFileDownloadManager)

    player.configure(authProvider: mockAuthProvider, baseURL: customBaseURL)

    #expect(player.listeningSessionReporter?.baseURL == customBaseURL)
  }

  @Test("Configure updates the player baseUrl")
  func testConfigureUpdatesPlayerBaseURL() async throws {
    let customBaseURL = URL(string: "http://localhost:6000/v1")!
    let mockAuthProvider = MockAuthProvider()
    let mockFileDownloadManager = MockFileDownloadManager()
    let player = PlayolaStationPlayer(fileDownloadManager: mockFileDownloadManager)

    player.configure(authProvider: mockAuthProvider, baseURL: customBaseURL)

    #expect(player.baseUrl == customBaseURL)
  }

  @Test("Configure uses default production baseURL when not specified")
  func testConfigureUsesDefaultBaseURL() async throws {
    let mockAuthProvider = MockAuthProvider()
    let mockFileDownloadManager = MockFileDownloadManager()
    let player = PlayolaStationPlayer(fileDownloadManager: mockFileDownloadManager)

    player.configure(authProvider: mockAuthProvider)

    #expect(
      player.listeningSessionReporter?.baseURL.absoluteString == "https://admin-api.playola.fm")
  }
}
