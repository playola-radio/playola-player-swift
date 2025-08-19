//
//  Test.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation
import Testing

@testable import PlayolaPlayer

private struct TestSpins {
  let pastSpin: Spin
  let currentSpin: Spin
  let futureSpin: Spin
}

struct ScheduleTests {

  @Test("Schedule initializes with correct properties")
  func testScheduleInitialization() throws {
    // Use the default mock schedule
    let schedule = Schedule.mock

    // Verify basic properties
    #expect(!schedule.stationId.isEmpty)
    #expect(!schedule.spins.isEmpty)

    // Create a schedule with custom properties
    let customStationId = "test-station-123"
    let customSpins = [Spin.mock]

    let customSchedule = Schedule(
      stationId: customStationId,
      spins: customSpins
    )

    // Verify custom properties
    #expect(customSchedule.stationId == customStationId)
    #expect(customSchedule.spins.count == customSpins.count)
    #expect(customSchedule.spins[0].id == customSpins[0].id)
  }

  @Test("Schedule.current returns spins that haven't ended yet")
  func testCurrentProperty() throws {
    // Create a date provider with a fixed mock time
    let mockTime = Date()
    let dateProviderMock = DateProviderMock(mockDate: mockTime)

    // Create some test spins
    let pastSpin = Spin.mockWith(
      id: "past-spin",
      airtime: mockTime.addingTimeInterval(-60),  // 1 minute ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      )
    )

    let currentSpin = Spin.mockWith(
      id: "current-spin",
      airtime: mockTime.addingTimeInterval(-15),  // 15 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      )
    )

    let futureSpin = Spin.mockWith(
      id: "future-spin",
      airtime: mockTime.addingTimeInterval(30),  // 30 seconds from now
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      )
    )

    // Create a schedule with these spins - maintain the original order for clarity in testing
    let schedule = Schedule(
      stationId: "test-station",
      spins: [pastSpin, currentSpin, futureSpin],
      dateProvider: dateProviderMock
    )

    // Current should only include spins whose endtime is after now
    // The order in current will be the same as in the original array: [currentSpin, futureSpin]
    #expect(schedule.current().count == 2)

    // Verify the correct spins are included without assuming order
    let currentIds = schedule.current().map { $0.id }
    #expect(currentIds.contains("current-spin"))
    #expect(currentIds.contains("future-spin"))
    #expect(!currentIds.contains("past-spin"))

    // Verify pastSpin's endtime is before now and thus excluded from current
    let pastSpinEndtime = pastSpin.endtime
    #expect(pastSpinEndtime < mockTime)
  }

  @Test("Schedule.nowPlaying returns the currently playing spin")
  func testNowPlayingProperty() throws {
    let mockTime = Date()
    let dateProviderMock = DateProviderMock(mockDate: mockTime)

    let testSpins = createTestSpinsForNowPlayingTest(
      mockTime: mockTime, dateProviderMock: dateProviderMock)
    verifySpinPlayingStates(testSpins: testSpins)

    let schedule = Schedule(
      stationId: "test-station",
      spins: [testSpins.pastSpin, testSpins.currentSpin, testSpins.futureSpin],
      dateProvider: dateProviderMock
    )

    // nowPlaying should be the currently playing spin
    #expect(schedule.nowPlaying()?.id == "current-spin")

    testOverlappingSpins(mockTime: mockTime, dateProviderMock: dateProviderMock)
  }

  private func createTestSpinsForNowPlayingTest(mockTime: Date, dateProviderMock: DateProviderMock)
    -> TestSpins
  {
    let pastSpin = Spin.mockWith(
      id: "past-spin",
      airtime: mockTime.addingTimeInterval(-60),  // 60 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000
      ),
      dateProvider: dateProviderMock
    )

    let currentSpin = Spin.mockWith(
      id: "current-spin",
      airtime: mockTime.addingTimeInterval(-15),  // 15 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000
      ),
      dateProvider: dateProviderMock
    )

    let futureSpin = Spin.mockWith(
      id: "future-spin",
      airtime: mockTime.addingTimeInterval(30),  // 30 seconds from now
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000
      ),
      dateProvider: dateProviderMock
    )

    return TestSpins(pastSpin: pastSpin, currentSpin: currentSpin, futureSpin: futureSpin)
  }

  private func verifySpinPlayingStates(testSpins: TestSpins) {
    #expect(!testSpins.pastSpin.isPlaying)  // Past spin should not be playing
    #expect(testSpins.currentSpin.isPlaying)  // Current spin should be playing
    #expect(!testSpins.futureSpin.isPlaying)  // Future spin should not be playing yet
  }

  private func testOverlappingSpins(mockTime: Date, dateProviderMock: DateProviderMock) {
    let playingSpin1 = Spin.mockWith(
      id: "playing-1",
      airtime: mockTime.addingTimeInterval(-20),  // 20 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 60000,  // 60 seconds duration
        endOfMessageMS: 60000  // Will finish in 40 seconds
      ),
      dateProvider: dateProviderMock
    )

    let playingSpin2 = Spin.mockWith(
      id: "playing-2",
      airtime: mockTime.addingTimeInterval(-10),  // 10 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 40000,  // 40 seconds duration
        endOfMessageMS: 40000  // Will finish in 30 seconds
      ),
      dateProvider: dateProviderMock
    )

    // Verify both spins are playing
    #expect(playingSpin1.isPlaying)
    #expect(playingSpin2.isPlaying)

    // Create schedule with overlapping playing spins
    let overlappingSchedule = Schedule(
      stationId: "test-station",
      spins: [playingSpin1, playingSpin2],
      dateProvider: dateProviderMock
    )

    // nowPlaying should be the last playing spin in the array
    #expect(overlappingSchedule.nowPlaying()?.id == "playing-2")
  }

  @Test("Schedule uses the injected DateProvider")
  func testDateProviderInjection() throws {
    // Create a spin that ended 10 seconds ago with a 30-second duration
    let spin = Spin.mockWith(
      airtime: Date().addingTimeInterval(-40),  // 40 seconds ago
      audioBlock: AudioBlock.mockWith(durationMS: 30000)  // 30 seconds duration
    )

    // Create two schedules with different time providers
    let pastProvider = DateProviderMock(mockDate: Date().addingTimeInterval(-60))  // 1 minute ago
    let futureProvider = DateProviderMock(mockDate: Date().addingTimeInterval(0))  // Now

    let pastSchedule = Schedule(
      stationId: "test-station",
      spins: [spin],
      dateProvider: pastProvider
    )

    let futureSchedule = Schedule(
      stationId: "test-station",
      spins: [spin],
      dateProvider: futureProvider
    )

    // With pastProvider (set to 1 minute ago), the spin should be in the future (not ended yet)
    #expect(!pastSchedule.current().isEmpty)

    // With futureProvider (set to now), the spin should be in the past (already ended)
    #expect(futureSchedule.current().isEmpty)
  }

  @Test("Schedule handles empty spins array")
  func testEmptySchedule() throws {
    // Create a schedule with no spins
    let emptySchedule = Schedule(
      stationId: "test-station",
      spins: []
    )

    // Verify that empty arrays are handled correctly
    #expect(emptySchedule.current().isEmpty)
    #expect(emptySchedule.nowPlaying() == nil)
  }

  @Test("Schedule correctly filters out past spins")
  func testPastSpinFiltering() throws {
    // Create a date provider with a fixed mock time
    let mockTime = Date()
    let dateProviderMock = DateProviderMock(mockDate: mockTime)

    // Create a schedule with spins of different durations that all started at the same time
    let shortSpin = Spin.mockWith(
      id: "short-spin",
      airtime: mockTime.addingTimeInterval(-40),  // 40 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 20000,  // 20 seconds duration
        endOfMessageMS: 20000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    let mediumSpin = Spin.mockWith(
      id: "medium-spin",
      airtime: mockTime.addingTimeInterval(-40),  // 40 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    let longSpin = Spin.mockWith(
      id: "long-spin",
      airtime: mockTime.addingTimeInterval(-40),  // 40 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 50000,  // 50 seconds duration
        endOfMessageMS: 50000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    // Create a schedule with these spins
    let schedule = Schedule(
      stationId: "test-station",
      spins: [shortSpin, mediumSpin, longSpin],
      dateProvider: dateProviderMock
    )

    // Current should contain only the spin that hasn't ended yet
    #expect(schedule.current().count == 1)
    #expect(schedule.current()[0].id == "long-spin")

    // nowPlaying should be longSpin since it's the only spin that's currently playing
    #expect(schedule.nowPlaying()?.id == "long-spin")
  }

  @Test("Schedule behavior when no spins are currently playing")
  func testNoCurrentlyPlayingSpins() throws {
    let mockTime = Date()
    let dateProviderMock = DateProviderMock(mockDate: mockTime)

    let futureSchedule = createFutureSpinsSchedule(
      mockTime: mockTime, dateProvider: dateProviderMock)
    #expect(futureSchedule.current().count == 2)
    #expect(futureSchedule.nowPlaying() == nil)

    let pastSchedule = createPastSpinsSchedule(mockTime: mockTime, dateProvider: dateProviderMock)
    #expect(pastSchedule.current().isEmpty)
    #expect(pastSchedule.nowPlaying() == nil)
  }

  private func createFutureSpinsSchedule(mockTime: Date, dateProvider: DateProviderMock) -> Schedule
  {
    let futureSpin1 = Spin.mockWith(
      id: "future-1",
      airtime: mockTime.addingTimeInterval(30),
      audioBlock: AudioBlock.mockWith(durationMS: 30000, endOfMessageMS: 30000),
      dateProvider: dateProvider
    )

    let futureSpin2 = Spin.mockWith(
      id: "future-2",
      airtime: mockTime.addingTimeInterval(60),
      audioBlock: AudioBlock.mockWith(durationMS: 30000, endOfMessageMS: 30000),
      dateProvider: dateProvider
    )

    return Schedule(
      stationId: "test-station", spins: [futureSpin1, futureSpin2], dateProvider: dateProvider)
  }

  private func createPastSpinsSchedule(mockTime: Date, dateProvider: DateProviderMock) -> Schedule {
    let pastSpin1 = Spin.mockWith(
      id: "past-1",
      airtime: mockTime.addingTimeInterval(-60),
      audioBlock: AudioBlock.mockWith(durationMS: 30000, endOfMessageMS: 30000),
      dateProvider: dateProvider
    )

    let pastSpin2 = Spin.mockWith(
      id: "past-2",
      airtime: mockTime.addingTimeInterval(-40),
      audioBlock: AudioBlock.mockWith(durationMS: 30000, endOfMessageMS: 30000),
      dateProvider: dateProvider
    )

    return Schedule(
      stationId: "test-station", spins: [pastSpin1, pastSpin2], dateProvider: dateProvider)
  }

  @Test("Schedule updates nowPlaying when spins change status")
  func testNowPlayingUpdates() throws {
    let mockTime = Date()
    let dateProviderMock = DateProviderMock(mockDate: mockTime)
    let testTimerProvider = TestTimerProvider()

    // Create test spins
    let currentSpin = Spin.mockWith(
      id: "current",
      airtime: mockTime.addingTimeInterval(-15),  // 15 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,
        endOfMessageMS: 30000  // Important: endOfMessageMS determines endtime
      ),
      dateProvider: dateProviderMock
    )

    let nextSpin = Spin.mockWith(
      id: "next",
      airtime: mockTime.addingTimeInterval(15),  // 15 seconds from now
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,
        endOfMessageMS: 30000  // Important: endOfMessageMS determines endtime
      ),
      dateProvider: dateProviderMock
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [currentSpin, nextSpin],
      dateProvider: dateProviderMock,
      timerProvider: testTimerProvider
    )

    // Initial state - currentSpin should be playing
    #expect(schedule.nowPlaying()?.id == "current")

    // Advance time to when nextSpin starts and execute timer
    dateProviderMock.setMockDate(mockTime.addingTimeInterval(15))
    testTimerProvider.executeNextTimer()

    // Now the nextSpin should be playing
    #expect(schedule.nowPlaying()?.id == "next")
  }

  @Test("Schedule properly handles nowPlaying transitions")
  func testNowPlayingTransitions() throws {
    let mockTime = Date()
    let dateProviderMock = DateProviderMock(mockDate: mockTime)
    let testTimerProvider = TestTimerProvider()

    let spin1 = Spin.mockWith(
      id: "spin1",
      airtime: mockTime,
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,
        endOfMessageMS: 30000  // Important: endOfMessageMS determines endtime
      ),
      dateProvider: dateProviderMock
    )

    let spin2 = Spin.mockWith(
      id: "spin2",
      airtime: mockTime.addingTimeInterval(30),
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,
        endOfMessageMS: 30000  // Important: endOfMessageMS determines endtime
      ),
      dateProvider: dateProviderMock
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [spin1, spin2],
      dateProvider: dateProviderMock,
      timerProvider: testTimerProvider
    )

    // At start (t=0)
    #expect(schedule.nowPlaying()?.id == "spin1")

    // Middle of first spin (t=15)
    dateProviderMock.setMockDate(mockTime.addingTimeInterval(15))
    testTimerProvider.executeNextTimer()
    #expect(schedule.nowPlaying()?.id == "spin1")

    // At transition (t=30)
    dateProviderMock.setMockDate(mockTime.addingTimeInterval(30))
    testTimerProvider.executeNextTimer()
    #expect(schedule.nowPlaying()?.id == "spin2")

    // After all spins (t=70)
    dateProviderMock.setMockDate(mockTime.addingTimeInterval(70))
    testTimerProvider.executeNextTimer()
    #expect(schedule.nowPlaying() == nil)
  }

  @Test("Schedule handles empty spins for nowPlaying")
  func testEmptySpinsNowPlaying() throws {
    let schedule = Schedule(
      stationId: "test-station",
      spins: []
    )

    #expect(schedule.nowPlaying() == nil)
  }

  // MARK: - Comprehensive Offset Tests

  @Test("Schedule offset functionality with comprehensive timeline")
  func testScheduleOffsetFunctionality() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    let testSpins = createComprehensiveTestSpins(now: now, dateProvider: dateProvider)
    let schedule = Schedule(
      stationId: "test-station",
      spins: Array(testSpins.values),
      dateProvider: dateProvider
    )

    testNowPlayingOffsets(schedule: schedule, testSpins: testSpins, now: now)
    testCurrentOffsets(schedule: schedule, now: now)
  }

  private func createComprehensiveTestSpins(now: Date, dateProvider: DateProviderMock)
    -> [String: Spin]
  {
    let spin1 = Spin.mockWith(  // Far past spin - ended before now
      id: "spin1",
      airtime: now.addingTimeInterval(-600),  // Started 10 min ago
      audioBlock: AudioBlock.mockWith(durationMS: 180000, endOfMessageMS: 180000),
      dateProvider: dateProvider
    )

    let spin2 = Spin.mockWith(  // Past spin - ended recently
      id: "spin2",
      airtime: now.addingTimeInterval(-300),  // Started 5 min ago
      audioBlock: AudioBlock.mockWith(durationMS: 120000, endOfMessageMS: 120000),
      dateProvider: dateProvider
    )

    let spin3 = Spin.mockWith(  // Recent past - still playing
      id: "spin3",
      airtime: now.addingTimeInterval(-120),  // Started 2 min ago
      audioBlock: AudioBlock.mockWith(durationMS: 180000, endOfMessageMS: 180000),
      dateProvider: dateProvider
    )

    let spin4 = Spin.mockWith(  // Current - just started (overlaps with spin3)
      id: "spin4",
      airtime: now.addingTimeInterval(-10),  // Started 10 sec ago
      audioBlock: AudioBlock.mockWith(durationMS: 240000, endOfMessageMS: 240000),
      dateProvider: dateProvider
    )

    let spin5 = Spin.mockWith(  // Near future
      id: "spin5",
      airtime: now.addingTimeInterval(300),  // Starts in 5 min
      audioBlock: AudioBlock.mockWith(durationMS: 180000, endOfMessageMS: 180000),
      dateProvider: dateProvider
    )

    let spin6 = Spin.mockWith(  // Far future - overlaps with spin5
      id: "spin6",
      airtime: now.addingTimeInterval(420),  // Starts in 7 min
      audioBlock: AudioBlock.mockWith(durationMS: 240000, endOfMessageMS: 240000),
      dateProvider: dateProvider
    )

    return [
      "spin1": spin1, "spin2": spin2, "spin3": spin3,
      "spin4": spin4, "spin5": spin5, "spin6": spin6,
    ]
  }

  private func testNowPlayingOffsets(schedule: Schedule, testSpins: [String: Spin], now: Date) {
    // At now (t=0): spin4 should be playing (most recent of overlapping spin3 and spin4)
    #expect(schedule.nowPlaying()?.id == "spin4")

    // Negative offset -90 seconds: applies +90 to spins
    // spin3 (originally -120) becomes -30, should be playing at "now"
    let spin3Playing = schedule.nowPlaying(offsetTimeInterval: -90)
    #expect(spin3Playing?.id == "spin3")
    #expect(spin3Playing?.airtime == now.addingTimeInterval(-30))  // -120 + 90 = -30

    // Negative offset -240 seconds: applies +240 to spins
    // spin2 (originally -300) becomes -60, should be playing at "now"
    let spin2Playing = schedule.nowPlaying(offsetTimeInterval: -240)
    #expect(spin2Playing?.id == "spin2")
    #expect(spin2Playing?.airtime == now.addingTimeInterval(-60))  // -300 + 240 = -60

    // Positive offset +360 seconds: applies -360 to spins
    // spin5 (originally +300) becomes -60, should be playing at "now"
    let spin5Playing = schedule.nowPlaying(offsetTimeInterval: 360)
    #expect(spin5Playing?.id == "spin5")
    #expect(spin5Playing?.airtime == now.addingTimeInterval(-60))  // 300 - 360 = -60

    // Positive offset +480 seconds: applies -480 to spins
    // spin6 (originally +420) becomes -60, should be playing at "now"
    let spin6Playing = schedule.nowPlaying(offsetTimeInterval: 480)
    #expect(spin6Playing?.id == "spin6")
    #expect(spin6Playing?.airtime == now.addingTimeInterval(-60))  // 420 - 480 = -60

    // Test edge cases
    testNowPlayingEdgeCases(schedule: schedule, testSpins: testSpins)
  }

  private func testNowPlayingEdgeCases(schedule: Schedule, testSpins: [String: Spin]) {
    // Test with nil offset - should behave like no offset
    let nilOffsetResult = schedule.nowPlaying(offsetTimeInterval: nil)
    #expect(nilOffsetResult?.id == "spin4")
    #expect(nilOffsetResult?.airtime == testSpins["spin4"]!.airtime)

    // Test when no spin is playing (large negative offset)
    let noSpinPlaying = schedule.nowPlaying(offsetTimeInterval: -750)
    #expect(noSpinPlaying == nil)
  }

  private func testCurrentOffsets(schedule: Schedule, now: Date) {
    // At now (t=0): should include spin3, spin4, spin5, spin6 (all not yet ended)
    let currentAtNow = schedule.current()
    #expect(currentAtNow.count == 4)
    let currentIds = currentAtNow.map { $0.id }
    #expect(!currentIds.contains("spin1"))  // spin1 has ended
    #expect(!currentIds.contains("spin2"))  // spin2 has ended
    #expect(currentIds.contains("spin3"))
    #expect(currentIds.contains("spin4"))
    #expect(currentIds.contains("spin5"))
    #expect(currentIds.contains("spin6"))

    testCurrentNegativeOffset(schedule: schedule)
    testCurrentPositiveOffset(schedule: schedule)
    testCurrentNilOffset(schedule: schedule, currentAtNow: currentAtNow)
  }

  private func testCurrentNegativeOffset(schedule: Schedule) {
    // Negative offset -180 seconds: applies +180 to spins
    let currentWithNegOffset = schedule.current(offsetTimeInterval: -240)
    #expect(currentWithNegOffset.count == 5)  // spin2 through spin6
    let negOffsetIds = currentWithNegOffset.map { $0.id }
    #expect(!negOffsetIds.contains("spin1"))
    #expect(negOffsetIds.contains("spin2"))
  }

  private func testCurrentPositiveOffset(schedule: Schedule) {
    // Positive offset +240 seconds: fewer spins remain current
    let currentWithPosOffset = schedule.current(offsetTimeInterval: 240)
    #expect(currentWithPosOffset.count == 2)  // only spin5 and spin6
    let posOffsetIds = currentWithPosOffset.map { $0.id }
    #expect(!posOffsetIds.contains("spin3"))  // ended
    #expect(!posOffsetIds.contains("spin4"))  // ended
    #expect(posOffsetIds.contains("spin5"))
    #expect(posOffsetIds.contains("spin6"))

    // Verify current() maintains sort order by airtime
    for i in 0..<(currentWithPosOffset.count - 1) {
      #expect(currentWithPosOffset[i].airtime <= currentWithPosOffset[i + 1].airtime)
    }
  }

  private func testCurrentNilOffset(schedule: Schedule, currentAtNow: [Spin]) {
    // Test with nil offset for current()
    let nilCurrentResult = schedule.current(offsetTimeInterval: nil)
    #expect(nilCurrentResult.count == currentAtNow.count)
    #expect(nilCurrentResult.map { $0.id } == currentAtNow.map { $0.id })
  }
}
