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
}
