//
//  Schedule.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Foundation
import Combine

public struct Schedule: Sendable {
    public let id = UUID()
    public let stationId: String
    public let spins: [Spin]
    public let dateProvider: DateProvider
    private let timerProvider: TimerProvider

  public var nowPlaying: Spin? {
    let now = dateProvider.now()
    return spins
      .filter { spin in
          // A spin is playing if current time is between its airtime and endtime
          spin.airtime <= now && spin.endtime > now
      }
      .sorted { $0.airtime > $1.airtime } // Sort by airtime descending
      .first
  }

    public init(stationId: String,
                spins: [Spin],
                dateProvider: DateProvider = .shared,
                timerProvider: TimerProvider = LiveTimerProvider.shared) {
        self.stationId = stationId
        self.spins = spins.map { spin in
            var updatedSpin = spin
            updatedSpin.dateProvider = dateProvider
            return updatedSpin
        }
        self.dateProvider = dateProvider
        self.timerProvider = timerProvider
    }

    public var current: [Spin] {
        let now = dateProvider.now()
        return spins.filter({ $0.endtime > now }).sorted { $0.airtime < $1.airtime }
    }
}

extension Schedule {
    public static let mock: Schedule = {
        let url = Bundle.module.url(forResource: "MockSchedule", withExtension: "json", subdirectory: "MockData")!
        let data = try! Data(contentsOf: url, options: .dataReadingMapped)
        let spins = try! JSONDecoderWithIsoFull().decode([Spin].self, from: data)
        return Schedule(stationId: spins[0].stationId, spins: spins)
    }()
}

extension Schedule: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Schedule, rhs: Schedule) -> Bool {
        return lhs.id == rhs.id
    }
}
