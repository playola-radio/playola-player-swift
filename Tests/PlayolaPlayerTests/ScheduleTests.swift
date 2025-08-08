//
//  Test.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation
import Testing

@testable import PlayolaPlayer

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
    // Create a date provider with a fixed mock time
    let mockTime = Date()
    let dateProviderMock = DateProviderMock(mockDate: mockTime)

    // Create test spins with different playing status

    // Spin that has already finished
    let pastSpin = Spin.mockWith(
      id: "past-spin",
      airtime: mockTime.addingTimeInterval(-60),  // 60 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    // Spin that is currently playing
    let currentSpin = Spin.mockWith(
      id: "current-spin",
      airtime: mockTime.addingTimeInterval(-15),  // 15 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    // Future spin that hasn't started yet
    let futureSpin = Spin.mockWith(
      id: "future-spin",
      airtime: mockTime.addingTimeInterval(30),  // 30 seconds from now
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    // First verify our test assumptions
    #expect(!pastSpin.isPlaying)  // Past spin should not be playing
    #expect(currentSpin.isPlaying)  // Current spin should be playing
    #expect(!futureSpin.isPlaying)  // Future spin should not be playing yet

    // Create a schedule with all three spins
    let schedule = Schedule(
      stationId: "test-station",
      spins: [pastSpin, currentSpin, futureSpin],
      dateProvider: dateProviderMock
    )

    // nowPlaying should be the currently playing spin
    #expect(schedule.nowPlaying()?.id == "current-spin")

    // Test with multiple concurrent playing spins
    // Create two overlapping playing spins
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
    // Create a date provider with a fixed mock time
    let mockTime = Date()
    let dateProviderMock = DateProviderMock(mockDate: mockTime)

    // Create only future spins
    let futureSpin1 = Spin.mockWith(
      id: "future-1",
      airtime: mockTime.addingTimeInterval(30),  // 30 seconds from now
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    let futureSpin2 = Spin.mockWith(
      id: "future-2",
      airtime: mockTime.addingTimeInterval(60),  // 60 seconds from now
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    // Create a schedule with only future spins
    let futureSchedule = Schedule(
      stationId: "test-station",
      spins: [futureSpin1, futureSpin2],
      dateProvider: dateProviderMock
    )

    // Current should contain both future spins
    #expect(futureSchedule.current().count == 2)

    // nowPlaying should be nil since no spins are currently playing
    #expect(futureSchedule.nowPlaying() == nil)

    // Create only past spins
    let pastSpin1 = Spin.mockWith(
      id: "past-1",
      airtime: mockTime.addingTimeInterval(-60),  // 60 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    let pastSpin2 = Spin.mockWith(
      id: "past-2",
      airtime: mockTime.addingTimeInterval(-40),  // 40 seconds ago
      audioBlock: AudioBlock.mockWith(
        durationMS: 30000,  // 30 seconds duration
        endOfMessageMS: 30000  // Important: endOfMessageMS is used for endtime calculation
      ),
      dateProvider: dateProviderMock
    )

    // Create a schedule with only past spins
    let pastSchedule = Schedule(
      stationId: "test-station",
      spins: [pastSpin1, pastSpin2],
      dateProvider: dateProviderMock
    )

    // Current should contain spins that haven't ended yet
    #expect(pastSchedule.current().isEmpty)

    // nowPlaying should be nil when no spins are playing
    #expect(pastSchedule.nowPlaying() == nil)
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

  // MARK: - offsetTimeInterval Tests

  @Test("nowPlaying with negative offset returns past spin with updated time")
  func testNowPlayingWithNegativeOffset() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    // Create a spin that was playing 5 minutes ago
    let pastSpin = Spin.mockWith(
      id: "past-spin",
      airtime: now.addingTimeInterval(-300),  // 5 minutes ago
      audioBlock: AudioBlock.mockWith(durationMS: 180000),  // 3 minute duration
      dateProvider: dateProvider
    )

    // Create a spin that is currently playing
    let currentSpin = Spin.mockWith(
      id: "current-spin",
      airtime: now.addingTimeInterval(-30),  // 30 seconds ago
      audioBlock: AudioBlock.mockWith(durationMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [pastSpin, currentSpin],
      dateProvider: dateProvider
    )

    // Without offset, should return current spin
    #expect(schedule.nowPlaying()?.id == "current-spin")

    // With -5 minute offset, should return the past spin with updated time
    let offsetSpin = schedule.nowPlaying(offsetTimeInterval: -300)
    #expect(offsetSpin?.id == "past-spin")

    // The returned spin should have its airtime adjusted by the offset
    #expect(offsetSpin?.airtime == now)  // Original was 5 min ago, offset brings it to now
  }

  @Test("nowPlaying with positive offset returns future spin with updated time")
  func testNowPlayingWithPositiveOffset() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    // Create a spin that is currently playing
    let currentSpin = Spin.mockWith(
      id: "current-spin",
      airtime: now.addingTimeInterval(-30),  // 30 seconds ago
      audioBlock: AudioBlock.mockWith(durationMS: 60000),  // 1 minute duration
      dateProvider: dateProvider
    )

    // Create a future spin
    let futureSpin = Spin.mockWith(
      id: "future-spin",
      airtime: now.addingTimeInterval(300),  // 5 minutes from now
      audioBlock: AudioBlock.mockWith(durationMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [currentSpin, futureSpin],
      dateProvider: dateProvider
    )

    // Without offset, should return current spin
    #expect(schedule.nowPlaying()?.id == "current-spin")

    // With +5 minute offset, should return the future spin with updated time
    let offsetSpin = schedule.nowPlaying(offsetTimeInterval: 300)
    #expect(offsetSpin?.id == "future-spin")

    // The returned spin should have its airtime adjusted by the offset
    #expect(offsetSpin?.airtime == now)  // Original was 5 min future, offset brings it to now
  }

  @Test("nowPlaying with nil offset behaves like no offset")
  func testNowPlayingWithNilOffset() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    let currentSpin = Spin.mockWith(
      id: "current-spin",
      airtime: now.addingTimeInterval(-30),
      audioBlock: AudioBlock.mockWith(durationMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [currentSpin],
      dateProvider: dateProvider
    )

    // Both calls should return the same result
    let withoutOffset = schedule.nowPlaying()
    let withNilOffset = schedule.nowPlaying(offsetTimeInterval: nil)

    #expect(withoutOffset?.id == withNilOffset?.id)
    #expect(withoutOffset?.airtime == withNilOffset?.airtime)
  }

  @Test("nowPlaying with offset returns nil when no spin matches")
  func testNowPlayingWithOffsetNoMatch() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    // Create only future spins
    let futureSpin = Spin.mockWith(
      id: "future-spin",
      airtime: now.addingTimeInterval(600),  // 10 minutes from now
      audioBlock: AudioBlock.mockWith(durationMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [futureSpin],
      dateProvider: dateProvider
    )

    // With -5 minute offset, still no spin playing at that time
    #expect(schedule.nowPlaying(offsetTimeInterval: -300) == nil)
  }

  @Test("current with negative offset returns past spins as current")
  func testCurrentWithNegativeOffset() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    // Create spins at different times
    let longPastSpin = Spin.mockWith(
      id: "long-past",
      airtime: now.addingTimeInterval(-600),  // 10 minutes ago
      audioBlock: AudioBlock.mockWith(durationMS: 60000),  // 1 minute duration (ended 9 min ago)
      dateProvider: dateProvider
    )

    let recentPastSpin = Spin.mockWith(
      id: "recent-past",
      airtime: now.addingTimeInterval(-180),  // 3 minutes ago
      audioBlock: AudioBlock.mockWith(durationMS: 60000),  // 1 minute duration (ended 2 min ago)
      dateProvider: dateProvider
    )

    let currentSpin = Spin.mockWith(
      id: "current",
      airtime: now.addingTimeInterval(-30),  // 30 seconds ago
      audioBlock: AudioBlock.mockWith(durationMS: 180000),  // 3 minute duration
      dateProvider: dateProvider
    )

    let futureSpin = Spin.mockWith(
      id: "future",
      airtime: now.addingTimeInterval(300),  // 5 minutes from now
      audioBlock: AudioBlock.mockWith(durationMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [longPastSpin, recentPastSpin, currentSpin, futureSpin],
      dateProvider: dateProvider
    )

    // Without offset, should only include current and future
    let currentSpins = schedule.current()
    #expect(currentSpins.count == 2)
    #expect(currentSpins.map { $0.id }.contains("current"))
    #expect(currentSpins.map { $0.id }.contains("future"))

    // With -5 minute offset, we go back to 5 minutes ago
    // At that time: longPastSpin had ended, recentPastSpin was future, current was future, future was further future
    let offsetSpins = schedule.current(offsetTimeInterval: -300)
    #expect(offsetSpins.count == 3)  // recentPast, current, and future

    // Verify the spins have adjusted airtimes
    let offsetRecentPast = offsetSpins.first { $0.id == "recent-past" }
    #expect(offsetRecentPast?.airtime == now.addingTimeInterval(120))  // -180 + 300 = 120
  }

  @Test("current with positive offset filters out soon-to-end spins")
  func testCurrentWithPositiveOffset() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    // Create spins with different end times
    let endingSoonSpin = Spin.mockWith(
      id: "ending-soon",
      airtime: now.addingTimeInterval(-50),  // 50 seconds ago
      audioBlock: AudioBlock.mockWith(durationMS: 60000),  // 1 minute duration (10 sec left)
      dateProvider: dateProvider
    )

    let endingLaterSpin = Spin.mockWith(
      id: "ending-later",
      airtime: now,  // Starting now
      audioBlock: AudioBlock.mockWith(durationMS: 180000),  // 3 minute duration
      dateProvider: dateProvider
    )

    let futureSpin = Spin.mockWith(
      id: "future",
      airtime: now.addingTimeInterval(300),  // 5 minutes from now
      audioBlock: AudioBlock.mockWith(durationMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [endingSoonSpin, endingLaterSpin, futureSpin],
      dateProvider: dateProvider
    )

    // Without offset, all spins are current
    #expect(schedule.current().count == 3)

    // With +30 second offset, endingSoonSpin should have ended
    let offsetSpins = schedule.current(offsetTimeInterval: 30)
    #expect(offsetSpins.count == 2)
    #expect(!offsetSpins.map { $0.id }.contains("ending-soon"))

    // Verify remaining spins have adjusted times
    let offsetEndingLater = offsetSpins.first { $0.id == "ending-later" }
    #expect(offsetEndingLater?.airtime == now.addingTimeInterval(-30))  // 0 - 30 = -30
  }

  @Test("current with nil offset behaves like no offset")
  func testCurrentWithNilOffset() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    let spin1 = Spin.mockWith(
      id: "spin1",
      airtime: now,
      audioBlock: AudioBlock.mockWith(durationMS: 180000),  // 3 minute duration
      dateProvider: dateProvider
    )
    let spin2 = Spin.mockWith(
      id: "spin2",
      airtime: now.addingTimeInterval(60),
      audioBlock: AudioBlock.mockWith(durationMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [spin1, spin2],
      dateProvider: dateProvider
    )

    // Both calls should return the same results
    let withoutOffset = schedule.current()
    let withNilOffset = schedule.current(offsetTimeInterval: nil)

    #expect(withoutOffset.count == withNilOffset.count)
    #expect(withoutOffset.map { $0.id } == withNilOffset.map { $0.id })

    // Verify airtimes are the same
    for i in 0..<withoutOffset.count {
      #expect(withoutOffset[i].airtime == withNilOffset[i].airtime)
    }
  }

  @Test("current with offset maintains sort order")
  func testCurrentWithOffsetMaintainsSortOrder() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    // Create spins in non-chronological order
    let spin3 = Spin.mockWith(
      id: "spin3",
      airtime: now.addingTimeInterval(180),  // 3 minutes from now
      audioBlock: AudioBlock.mockWith(durationMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let spin1 = Spin.mockWith(
      id: "spin1",
      airtime: now.addingTimeInterval(60),  // 1 minute from now
      audioBlock: AudioBlock.mockWith(durationMS: 180000),  // 3 minute duration
      dateProvider: dateProvider
    )

    let spin2 = Spin.mockWith(
      id: "spin2",
      airtime: now.addingTimeInterval(120),  // 2 minutes from now
      audioBlock: AudioBlock.mockWith(durationMS: 150000),  // 2.5 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [spin3, spin1, spin2],  // Intentionally out of order
      dateProvider: dateProvider
    )

    // Get current with offset
    let offsetSpins = schedule.current(offsetTimeInterval: -60)

    // Verify they are sorted by airtime (after offset adjustment)
    #expect(offsetSpins.count == 3)
    #expect(offsetSpins[0].id == "spin1")  // Should be first (airtime: now)
    #expect(offsetSpins[1].id == "spin2")  // Should be second (airtime: now + 60)
    #expect(offsetSpins[2].id == "spin3")  // Should be third (airtime: now + 120)

    // Verify the adjusted airtimes
    #expect(offsetSpins[0].airtime == now)
    #expect(offsetSpins[1].airtime == now.addingTimeInterval(60))
    #expect(offsetSpins[2].airtime == now.addingTimeInterval(120))
  }

  @Test("nowPlaying with offset handles overlapping spins correctly")
  func testNowPlayingWithOffsetOverlappingSpins() throws {
    let dateProvider = DateProviderMock()
    let now = Date()
    dateProvider.setMockDate(now)

    // Create overlapping spins
    let spin1 = Spin.mockWith(
      id: "spin1",
      airtime: now.addingTimeInterval(-120),  // 2 minutes ago
      audioBlock: AudioBlock.mockWith(durationMS: 180000, endOfMessageMS: 180000),  // 3 minute duration
      dateProvider: dateProvider
    )

    let spin2 = Spin.mockWith(
      id: "spin2",
      airtime: now.addingTimeInterval(-60),  // 1 minute ago
      audioBlock: AudioBlock.mockWith(durationMS: 120000, endOfMessageMS: 120000),  // 2 minute duration
      dateProvider: dateProvider
    )

    let schedule = Schedule(
      stationId: "test-station",
      spins: [spin1, spin2],
      dateProvider: dateProvider
    )

    // Both spins are currently playing, should return spin2 (most recent)
    #expect(schedule.nowPlaying()?.id == "spin2")

    // With -90 second offset (go back to 1.5 minutes ago)
    // At that time, only spin1 was playing
    let offsetSpin = schedule.nowPlaying(offsetTimeInterval: -90)
    #expect(offsetSpin?.id == "spin1")
    #expect(offsetSpin?.airtime == now.addingTimeInterval(-30))  // -120 + 90 = -30
  }
}
