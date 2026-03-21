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

  private struct PlayerTestContext {
    let player: StreamingSpinPlayer
    let mock: MockAVPlayer
    let delegate: MockStreamingSpinPlayerDelegate
  }

  private func createPlayer(mockPlayer: MockAVPlayer? = nil) -> PlayerTestContext {
    let mock = mockPlayer ?? MockAVPlayer()
    let delegate = MockStreamingSpinPlayerDelegate()
    let player = StreamingSpinPlayer(
      delegate: delegate,
      playerFactory: { mock }
    )
    return PlayerTestContext(player: player, mock: mock, delegate: delegate)
  }

  // MARK: - Initial State

  @Test("Initial state is available")
  func testInitialState() {
    let ctx = createPlayer()
    #expect(ctx.player.state == .available)
    #expect(ctx.player.spin == nil)
  }

  // MARK: - Load

  @Test("Load with nil downloadUrl fails immediately")
  func testLoadNilDownloadUrl() async {
    let ctx = createPlayer()
    let audioBlock = AudioBlock(
      id: "test", title: "Test", artist: "Test", durationMS: 30000,
      endOfMessageMS: 28000, beginningOfOutroMS: 25000, endOfIntroMS: 5000,
      lengthOfOutroMS: 5000, downloadUrl: nil, s3Key: "key", s3BucketName: "bucket",
      type: "song", createdAt: Date(), updatedAt: Date(), album: nil, popularity: nil,
      youTubeId: nil, isrc: nil, spotifyId: nil, imageUrl: nil as URL?
    )
    let spin = Spin.mockWith(audioBlock: audioBlock)

    let result = await ctx.player.load(spin)

    switch result {
    case .success:
      Issue.record("Expected failure for nil downloadUrl")
    case .failure:
      #expect(ctx.player.state == .available)
    }
  }

  @Test("Successful load transitions to loaded state")
  func testLoadSuccess() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)
    let spin = Spin.mockWith()

    let result = await ctx.player.load(spin)

    switch result {
    case .success:
      #expect(ctx.player.state == .loaded)
      #expect(ctx.player.spin?.id == spin.id)
      #expect(mock.loadedURL != nil)
      #expect(ctx.delegate.stateChanges.contains(.loading))
      #expect(ctx.delegate.stateChanges.contains(.loaded))
    case .failure(let error):
      Issue.record("Expected success but got: \(error)")
    }
  }

  @Test("Failed load transitions to error state")
  func testLoadFailure() async {
    let mock = MockAVPlayer()
    mock.shouldFailLoad = true
    let ctx = createPlayer(mockPlayer: mock)
    let spin = Spin.mockWith()

    let result = await ctx.player.load(spin)

    switch result {
    case .success:
      Issue.record("Expected failure")
    case .failure:
      #expect(ctx.player.state == .error)
      #expect(ctx.delegate.stateChanges.contains(.loading))
      #expect(ctx.delegate.stateChanges.contains(.error))
    }
  }

  @Test("Load builds fade schedule")
  func testFadeScheduleBuiltDuringLoad() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [Fade(atMS: 10000, toVolume: 0.0)]
    )

    _ = await ctx.player.load(spin)

    #expect(!ctx.player.fadeSchedule.isEmpty)
    #expect(ctx.player.fadeSchedule.count == FadeScheduleBuilder.fadeSteps + 1)
  }

  // MARK: - Clear

  @Test("Clear resets all state")
  func testClear() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await ctx.player.load(spin)

    ctx.player.clear()

    #expect(ctx.player.state == .available)
    #expect(ctx.player.spin == nil)
    #expect(mock.pauseCallCount == 1)
    #expect(mock.clearItemCallCount == 1)
    #expect(ctx.player.fadeSchedule.isEmpty)
  }

  // MARK: - Stop

  @Test("Stop calls clear")
  func testStop() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await ctx.player.load(spin)

    ctx.player.stop()

    #expect(ctx.player.state == .available)
    #expect(ctx.player.spin == nil)
    #expect(mock.pauseCallCount == 1)
  }

  // MARK: - PlayNow

  @Test("PlayNow with offset past endOfMessage clears player")
  func testPlayNowPastEndOfMessage() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      audioBlock: AudioBlock.mockWith(endOfMessageMS: 30000)
    )
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 31.0)  // 31 seconds > 30s endOfMessage

    #expect(ctx.player.state == .available)
    #expect(ctx.player.spin == nil)
  }

  @Test("PlayNow when not loaded is a no-op")
  func testPlayNowNotLoaded() {
    let ctx = createPlayer()
    ctx.player.spin = Spin.mockWith()

    ctx.player.playNow(from: 5.0)

    #expect(ctx.mock.playCallCount == 0)
    #expect(ctx.player.state == .available)
  }

  @Test("PlayNow sets volume from fade schedule")
  func testPlayNowSetsVolume() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      startingVolume: 0.8,
      fades: []
    )
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 0.0)

    // Give the async Task inside playNow a moment
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.volume == 0.8)
  }

  // MARK: - SchedulePlay

  @Test("SchedulePlay when not loaded is a no-op")
  func testSchedulePlayNotLoaded() {
    let ctx = createPlayer()

    ctx.player.schedulePlay(at: Date().addingTimeInterval(10))

    #expect(ctx.mock.playCallCount == 0)
  }

  @Test("SchedulePlay sets initial volume")
  func testSchedulePlaySetsVolume() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(startingVolume: 0.6)
    _ = await ctx.player.load(spin)

    ctx.player.schedulePlay(at: Date().addingTimeInterval(10))

    #expect(mock.volume == 0.6)
  }

  // MARK: - State Transitions

  @Test("Delegate receives state changes")
  func testDelegateReceivesStateChanges() {
    let ctx = createPlayer()

    ctx.player.state = .loading
    ctx.player.state = .loaded
    ctx.player.state = .playing

    #expect(ctx.delegate.stateChanges == [.loading, .loaded, .playing])
  }

  @Test("Duplicate state changes are not reported")
  func testNoDuplicateStateChanges() {
    let ctx = createPlayer()

    ctx.player.state = .loading
    ctx.player.state = .loading  // duplicate

    #expect(ctx.delegate.stateChanges == [.loading])
  }
}
