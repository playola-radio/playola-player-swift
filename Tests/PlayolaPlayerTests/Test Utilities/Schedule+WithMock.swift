//
//  Schedule+WithMock.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/22/25.
//
import Foundation

@testable import PlayolaPlayer

// Extension to provide additional mock utilities for testing
extension Schedule {
  /// Creates a mock Schedule with optional property overrides
  /// - Parameters:
  ///   - stationId: Optional override for station ID
  ///   - spins: Optional override for the spins array
  ///   - dateProvider: Optional override for date provider
  /// - Returns: A mock Schedule with specified overrides
  public static func mockWith(
    stationId: String? = nil,
    spins: [Spin]? = nil,
    dateProvider: DateProvider? = nil
  ) -> Schedule {
    // Start with the default mock
    let mockSchedule = Schedule.mock

    // Create new schedule with overrides
    return Schedule(
      stationId: stationId ?? mockSchedule.stationId,
      spins: spins ?? mockSchedule.spins,
      dateProvider: dateProvider ?? mockSchedule.dateProvider
    )
  }

  /// Creates a mock Schedule with spins at specified time intervals from now
  /// - Parameters:
  ///   - stationId: Optional station ID (defaults to mock station ID)
  ///   - spinCount: Number of spins to create
  ///   - spinDurationSeconds: Duration of each spin in seconds
  ///   - gapSeconds: Gap between spins in seconds
  ///   - startOffsetSeconds: Offset from now for the first spin (negative means in the past)
  ///   - dateProvider: Optional date provider (defaults to a new mock)
  /// - Returns: A Schedule with specified temporal pattern of spins
  public static func mockWithTimePattern(
    stationId: String? = nil,
    spinCount: Int = 10,
    spinDurationSeconds: Int = 30,
    gapSeconds: Int = 0,
    startOffsetSeconds: TimeInterval = -120,  // 2 minutes ago by default
    dateProvider: DateProvider = DateProviderMock()
  ) -> Schedule {
    let mockScheduleId = stationId ?? Schedule.mock.stationId
    let now = Date()
    var spins: [Spin] = []

    // Start time for the first spin
    var currentStartTime = now.addingTimeInterval(startOffsetSeconds)

    for i in 0..<spinCount {
      // Create AudioBlock with specified duration
      let audioBlock = AudioBlock.mockWith(
        id: "audio-\(i)",
        title: "Song \(i)",
        artist: "Artist \(i)",
        durationMS: spinDurationSeconds * 1000,
        endOfMessageMS: spinDurationSeconds * 1000
      )

      // Create the spin
      let spin = Spin.mockWith(
        id: "spin-\(i)",
        airtime: currentStartTime,
        stationId: mockScheduleId,
        audioBlock: audioBlock,
        dateProvider: dateProvider
      )

      spins.append(spin)

      // Update start time for next spin
      let totalDuration = Double(spinDurationSeconds + gapSeconds)
      currentStartTime = currentStartTime.addingTimeInterval(totalDuration)
    }

    return Schedule(
      stationId: mockScheduleId,
      spins: spins,
      dateProvider: dateProvider
    )
  }
}
