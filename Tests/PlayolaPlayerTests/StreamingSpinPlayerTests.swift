import AVFoundation
import Foundation
import Testing

@testable import PlayolaCore
@testable import PlayolaPlayer

// MARK: - Mock AVPlayer

@MainActor
final class MockAVPlayer: AVPlayerProviding {
  var volume: Float = 1.0
  var currentTimeSeconds: Double = 0.0

  var playCallCount = 0
  var pauseCallCount = 0
  var seekTarget: CMTime?
  var loadedURL: URL?
  var clearItemCallCount = 0

  var shouldFailLoad = false
  var loadError: Error = StationPlayerError.playbackError("Mock load failure")

  func play() {
    playCallCount += 1
  }

  func pause() {
    pauseCallCount += 1
  }

  func seek(to time: CMTime) async -> Bool {
    seekTarget = time
    return true
  }

  func loadURL(_ url: URL) async throws {
    loadedURL = url
    if shouldFailLoad {
      throw loadError
    }
  }

  func clearItem() {
    clearItemCallCount += 1
  }
}

// MARK: - Mock Delegate

@MainActor
final class MockStreamingSpinPlayerDelegate: StreamingSpinPlayerDelegate {
  var startedPlayingSpins: [Spin] = []
  var stateChanges: [StreamingSpinPlayer.State] = []
  var errors: [Error] = []

  func streamingPlayer(_ player: StreamingSpinPlayer, startedPlaying spin: Spin) {
    startedPlayingSpins.append(spin)
  }

  func streamingPlayer(
    _ player: StreamingSpinPlayer, didChangeState state: StreamingSpinPlayer.State
  ) {
    stateChanges.append(state)
  }

  func streamingPlayer(_ player: StreamingSpinPlayer, didEncounterError error: Error) {
    errors.append(error)
  }
}

// MARK: - Tests

@MainActor
struct StreamingSpinPlayerTests {

  private func createPlayer(mockPlayer: MockAVPlayer? = nil) -> (
    StreamingSpinPlayer, MockAVPlayer, MockStreamingSpinPlayerDelegate
  ) {
    let mock = mockPlayer ?? MockAVPlayer()
    let delegate = MockStreamingSpinPlayerDelegate()
    let player = StreamingSpinPlayer(
      delegate: delegate,
      playerFactory: { mock }
    )
    return (player, mock, delegate)
  }

  // MARK: - Initial State

  @Test("Initial state is available")
  func testInitialState() {
    let (player, _, _) = createPlayer()
    #expect(player.state == .available)
    #expect(player.spin == nil)
  }

  // MARK: - Load

  @Test("Load with nil downloadUrl fails immediately")
  func testLoadNilDownloadUrl() async {
    let (player, _, _) = createPlayer()
    let audioBlock = AudioBlock(
      id: "test", title: "Test", artist: "Test", durationMS: 30000,
      endOfMessageMS: 28000, beginningOfOutroMS: 25000, endOfIntroMS: 5000,
      lengthOfOutroMS: 5000, downloadUrl: nil, s3Key: "key", s3BucketName: "bucket",
      type: "song", createdAt: Date(), updatedAt: Date(), album: nil, popularity: nil,
      youTubeId: nil, isrc: nil, spotifyId: nil, imageUrl: nil as URL?
    )
    let spin = Spin.mockWith(audioBlock: audioBlock)

    let result = await player.load(spin)

    switch result {
    case .success:
      Issue.record("Expected failure for nil downloadUrl")
    case .failure:
      #expect(player.state == .available)
    }
  }

  @Test("Successful load transitions to loaded state")
  func testLoadSuccess() async {
    let mock = MockAVPlayer()
    let (player, _, delegate) = createPlayer(mockPlayer: mock)
    let spin = Spin.mockWith()

    let result = await player.load(spin)

    switch result {
    case .success:
      #expect(player.state == .loaded)
      #expect(player.spin?.id == spin.id)
      #expect(mock.loadedURL != nil)
      #expect(delegate.stateChanges.contains(.loading))
      #expect(delegate.stateChanges.contains(.loaded))
    case .failure(let error):
      Issue.record("Expected success but got: \(error)")
    }
  }

  @Test("Failed load transitions to error state")
  func testLoadFailure() async {
    let mock = MockAVPlayer()
    mock.shouldFailLoad = true
    let (player, _, delegate) = createPlayer(mockPlayer: mock)
    let spin = Spin.mockWith()

    let result = await player.load(spin)

    switch result {
    case .success:
      Issue.record("Expected failure")
    case .failure:
      #expect(player.state == .error)
      #expect(delegate.stateChanges.contains(.loading))
      #expect(delegate.stateChanges.contains(.error))
    }
  }

  @Test("Load builds fade schedule")
  func testFadeScheduleBuiltDuringLoad() async {
    let mock = MockAVPlayer()
    let (player, _, _) = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [Fade(atMS: 10000, toVolume: 0.0)]
    )

    _ = await player.load(spin)

    #expect(!player.fadeSchedule.isEmpty)
    #expect(player.fadeSchedule.count == FadeScheduleBuilder.fadeSteps + 1)
  }

  // MARK: - Clear

  @Test("Clear resets all state")
  func testClear() async {
    let mock = MockAVPlayer()
    let (player, _, _) = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await player.load(spin)

    player.clear()

    #expect(player.state == .available)
    #expect(player.spin == nil)
    #expect(mock.pauseCallCount == 1)
    #expect(mock.clearItemCallCount == 1)
    #expect(player.fadeSchedule.isEmpty)
  }

  // MARK: - Stop

  @Test("Stop calls clear")
  func testStop() async {
    let mock = MockAVPlayer()
    let (player, _, _) = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await player.load(spin)

    player.stop()

    #expect(player.state == .available)
    #expect(player.spin == nil)
    #expect(mock.pauseCallCount == 1)
  }

  // MARK: - PlayNow

  @Test("PlayNow with offset past endOfMessage clears player")
  func testPlayNowPastEndOfMessage() async {
    let mock = MockAVPlayer()
    let (player, _, _) = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      audioBlock: AudioBlock.mockWith(endOfMessageMS: 30000)
    )
    _ = await player.load(spin)

    player.playNow(from: 31.0)  // 31 seconds > 30s endOfMessage

    #expect(player.state == .available)
    #expect(player.spin == nil)
  }

  @Test("PlayNow when not loaded is a no-op")
  func testPlayNowNotLoaded() {
    let (player, mock, _) = createPlayer()
    player.spin = Spin.mockWith()

    player.playNow(from: 5.0)

    #expect(mock.playCallCount == 0)
    #expect(player.state == .available)
  }

  @Test("PlayNow sets volume from fade schedule")
  func testPlayNowSetsVolume() async {
    let mock = MockAVPlayer()
    let (player, _, _) = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      startingVolume: 0.8,
      fades: []
    )
    _ = await player.load(spin)

    player.playNow(from: 0.0)

    // Give the async Task inside playNow a moment
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.volume == 0.8)
  }

  // MARK: - SchedulePlay

  @Test("SchedulePlay when not loaded is a no-op")
  func testSchedulePlayNotLoaded() {
    let (player, mock, _) = createPlayer()

    player.schedulePlay(at: Date().addingTimeInterval(10))

    #expect(mock.playCallCount == 0)
  }

  @Test("SchedulePlay sets initial volume")
  func testSchedulePlaySetsVolume() async {
    let mock = MockAVPlayer()
    let (player, _, _) = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(startingVolume: 0.6)
    _ = await player.load(spin)

    player.schedulePlay(at: Date().addingTimeInterval(10))

    #expect(mock.volume == 0.6)
  }

  // MARK: - State Transitions

  @Test("Delegate receives state changes")
  func testDelegateReceivesStateChanges() {
    let (player, _, delegate) = createPlayer()

    player.state = .loading
    player.state = .loaded
    player.state = .playing

    #expect(delegate.stateChanges == [.loading, .loaded, .playing])
  }

  @Test("Duplicate state changes are not reported")
  func testNoDuplicateStateChanges() {
    let (player, _, delegate) = createPlayer()

    player.state = .loading
    player.state = .loading  // duplicate

    #expect(delegate.stateChanges == [.loading])
  }
}
