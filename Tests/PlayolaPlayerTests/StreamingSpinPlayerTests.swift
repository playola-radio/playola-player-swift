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

  // Boundary observer tracking
  var registeredBoundaryTimes: [NSValue] = []
  var boundaryCallback: (@Sendable () -> Void)?
  var addBoundaryObserverCallCount = 0
  var removeBoundaryObserverCallCount = 0
  private let boundaryToken = NSObject()

  // Preroll tracking
  var prerollCallCount = 0
  var prerollShouldSucceed = true
  var cancelPendingPrerollsCallCount = 0

  // setRate tracking
  var setRateCallCount = 0
  var lastSetRate: Float?
  var lastSetRateTime: CMTime?
  var lastSetRateHostTime: CMTime?

  // Stall callbacks
  var onStall: (() -> Void)?
  var onUnstall: (() -> Void)?

  // Call ordering
  var callLog: [String] = []

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
    callLog.append("clearItem")
    clearItemCallCount += 1
  }

  func addBoundaryTimeObserver(
    forTimes times: [NSValue],
    queue: DispatchQueue?,
    using block: @escaping @Sendable () -> Void
  ) -> Any {
    registeredBoundaryTimes = times
    boundaryCallback = block
    addBoundaryObserverCallCount += 1
    return boundaryToken
  }

  func removeBoundaryTimeObserver(_ token: Any) {
    callLog.append("removeBoundaryTimeObserver")
    removeBoundaryObserverCallCount += 1
  }

  func preroll(atRate rate: Float) async -> Bool {
    prerollCallCount += 1
    return prerollShouldSucceed
  }

  func cancelPendingPrerolls() {
    callLog.append("cancelPendingPrerolls")
    cancelPendingPrerollsCallCount += 1
  }

  func setRate(_ rate: Float, time: CMTime, atHostTime hostTime: CMTime) {
    callLog.append("setRate")
    setRateCallCount += 1
    lastSetRate = rate
    lastSetRateTime = time
    lastSetRateHostTime = hostTime
  }

  func fireBoundaryCallback() {
    boundaryCallback?()
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
@Suite(.serialized)
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

  // MARK: - Boundary Observer Fades

  @Test("PlayNow registers boundary observer with correct number of fade times")
  func testPlayNowRegistersBoundaryObserver() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      airtime: Date(),
      startingVolume: 1.0,
      fades: [Fade(atMS: 10000, toVolume: 0.0)]
    )
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 0.0)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.addBoundaryObserverCallCount == 1)
    #expect(mock.registeredBoundaryTimes.count == FadeScheduleBuilder.fadeSteps + 1)
  }

  @Test("Boundary observer callback sets correct volume")
  func testBoundaryCallbackSetsVolume() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      airtime: Date(),
      startingVolume: 1.0,
      fades: [Fade(atMS: 10000, toVolume: 0.0)]
    )
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 0.0)
    try? await Task.sleep(for: .milliseconds(50))

    // Simulate playback reaching a fade step midway through
    let midIndex = FadeScheduleBuilder.fadeSteps / 2
    let midStep = ctx.player.fadeSchedule[midIndex]
    mock.currentTimeSeconds = Double(midStep.timeMS) / 1000.0

    mock.fireBoundaryCallback()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.volume == midStep.volume)
  }

  @Test("Boundary observer token removed on clear")
  func testBoundaryObserverRemovedOnClear() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      airtime: Date(),
      startingVolume: 1.0,
      fades: [Fade(atMS: 10000, toVolume: 0.0)]
    )
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 0.0)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.addBoundaryObserverCallCount == 1)

    ctx.player.clear()

    #expect(mock.removeBoundaryObserverCallCount == 1)
  }

  @Test("removeBoundaryTimeObserver called before clearItem on clear")
  func testBoundaryObserverRemovedBeforeClearItem() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      airtime: Date(),
      startingVolume: 1.0,
      fades: [Fade(atMS: 10000, toVolume: 0.0)]
    )
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 0.0)
    try? await Task.sleep(for: .milliseconds(100))

    mock.callLog.removeAll()
    ctx.player.clear()

    #expect(mock.callLog == ["removeBoundaryTimeObserver", "cancelPendingPrerolls", "clearItem"])
  }

  @Test("Mid-join boundary observer starts from correct fade index")
  func testMidJoinBoundaryObserverStartsFromCorrectIndex() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    // Fade at 5000ms lasts 1500ms, ending at 6500ms
    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [Fade(atMS: 5000, toVolume: 0.0)]
    )
    _ = await ctx.player.load(spin)

    // Join at 7 seconds — past the entire fade (5000ms + 1500ms = 6500ms)
    ctx.player.playNow(from: 7.0)
    try? await Task.sleep(for: .milliseconds(100))

    // All fade steps are before 7s, so no boundary times should be registered
    #expect(mock.registeredBoundaryTimes.isEmpty)
    #expect(mock.addBoundaryObserverCallCount == 0)
  }

  @Test("Boundary observer not registered when no fades")
  func testNoBoundaryObserverWithoutFades() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(startingVolume: 1.0, fades: [])
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 0.0)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.addBoundaryObserverCallCount == 0)
  }

  // MARK: - Preroll

  @Test("Preroll called after successful load")
  func testPrerollCalledAfterLoad() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await ctx.player.load(spin)

    #expect(mock.prerollCallCount == 1)
    #expect(ctx.player.isPrerolled == true)
  }

  @Test("Preroll failure sets isPrerolled to false")
  func testPrerollFailure() async {
    let mock = MockAVPlayer()
    mock.prerollShouldSucceed = false
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await ctx.player.load(spin)

    #expect(mock.prerollCallCount == 1)
    #expect(ctx.player.isPrerolled == false)
  }

  @Test("cancelPendingPrerolls called on clear")
  func testCancelPendingPrerollsOnClear() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await ctx.player.load(spin)

    ctx.player.clear()

    #expect(mock.cancelPendingPrerollsCallCount == 1)
  }

  @Test("isPrerolled reset on clear")
  func testIsPrerolledResetOnClear() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await ctx.player.load(spin)
    #expect(ctx.player.isPrerolled == true)

    ctx.player.clear()

    #expect(ctx.player.isPrerolled == false)
  }

  // MARK: - Host-Time-Synced SchedulePlay

  @Test("SchedulePlay uses setRate when prerolled")
  func testSchedulePlayUsesSetRate() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(airtime: Date().addingTimeInterval(60))
    _ = await ctx.player.load(spin)
    #expect(ctx.player.isPrerolled == true)

    ctx.player.schedulePlay(at: Date().addingTimeInterval(10))

    #expect(mock.setRateCallCount == 1)
    #expect(mock.lastSetRate == 1.0)
    #expect(mock.playCallCount == 0)
  }

  @Test("SchedulePlay falls back to Timer when not prerolled")
  func testSchedulePlayFallsBackToTimer() async {
    let mock = MockAVPlayer()
    mock.prerollShouldSucceed = false
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(airtime: Date().addingTimeInterval(60))
    _ = await ctx.player.load(spin)
    #expect(ctx.player.isPrerolled == false)

    ctx.player.schedulePlay(at: Date().addingTimeInterval(10))

    #expect(mock.setRateCallCount == 0)
    #expect(mock.playCallCount == 0)  // Timer hasn't fired yet
  }

  @Test("SchedulePlay with past date uses play() as fallback")
  func testSchedulePlayPastDateUsesPlay() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(airtime: Date().addingTimeInterval(60))
    _ = await ctx.player.load(spin)

    ctx.player.schedulePlay(at: Date().addingTimeInterval(-1))

    #expect(mock.playCallCount == 1)
    #expect(mock.setRateCallCount == 0)
  }

  // MARK: - Stall Recovery

  @Test("Stall callbacks set up after load")
  func testStallCallbacksSetUp() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith()
    _ = await ctx.player.load(spin)

    #expect(mock.onStall != nil)
    #expect(mock.onUnstall != nil)
  }

  @Test("Unstall callback calls play to resume")
  func testUnstallResumesPlayback() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(airtime: Date())
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 0.0)
    try? await Task.sleep(for: .milliseconds(50))

    let playCountBefore = mock.playCallCount
    mock.onUnstall?()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.playCallCount == playCountBefore + 1)
  }

  @Test("Stall does not change state")
  func testStallDoesNotChangeState() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(airtime: Date())
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 0.0)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(ctx.player.state == .playing)

    mock.onStall?()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(ctx.player.state == .playing)
  }

  // MARK: - Playback Start Observer

  @Test("SchedulePlay with preroll registers playback start observer")
  func testSchedulePlayRegistersStartObserver() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(airtime: Date().addingTimeInterval(60))
    _ = await ctx.player.load(spin)

    ctx.player.schedulePlay(at: Date().addingTimeInterval(10))

    // One for playback start (0.001s), plus boundary fades if any
    #expect(mock.addBoundaryObserverCallCount >= 1)
  }

  // MARK: - Mid-Song Join with setRate

  @Test("PlayNow uses setRate instead of play")
  func testPlayNowUsesSetRate() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(airtime: Date())
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 5.0)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.setRateCallCount == 1)
    #expect(mock.lastSetRate == 1.0)
    #expect(mock.playCallCount == 0)
  }

  @Test("PlayNow setRate uses correct seek time")
  func testPlayNowSetRateSeekTime() async {
    let mock = MockAVPlayer()
    let ctx = createPlayer(mockPlayer: mock)

    let spin = Spin.mockWith(
      airtime: Date(),
      audioBlock: AudioBlock.mockWith(endOfMessageMS: 300_000)
    )
    _ = await ctx.player.load(spin)

    ctx.player.playNow(from: 12.5)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(mock.setRateCallCount == 1)
    let expectedTime = CMTime(seconds: 12.5, preferredTimescale: 600)
    #expect(mock.lastSetRateTime == expectedTime)
  }
}
