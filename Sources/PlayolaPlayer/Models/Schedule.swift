//
//  Schedule.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Combine
import Foundation

public struct Schedule: Sendable {
  public let id = UUID()
  public let stationId: String
  public let spins: [Spin]
  public let dateProvider: DateProviderProtocol
  private let timerProvider: TimerProvider

  public func current(offsetTimeInterval: TimeInterval? = nil) -> [Spin] {
    let adjustedSpins = adjustedSpins(offsetTimeInterval: offsetTimeInterval)
    return adjustedSpins.filter({ $0.endtime > dateProvider.now() }).sorted {
      $0.airtime < $1.airtime
    }
  }

  public init(
    stationId: String,
    spins: [Spin],
    dateProvider: DateProviderProtocol? = nil,
    timerProvider: TimerProvider = LiveTimerProvider.shared
  ) {
    self.stationId = stationId
    let dateProvider = dateProvider ?? DateProvider()
    self.spins = spins.map { spin in
      var updatedSpin = spin
      updatedSpin.dateProvider = dateProvider
      return updatedSpin
    }
    self.dateProvider = dateProvider
    self.timerProvider = timerProvider
  }

  public func nowPlaying(offsetTimeInterval: TimeInterval? = nil) -> Spin? {
    let adjustedSpins = adjustedSpins(offsetTimeInterval: offsetTimeInterval)
    let now = dateProvider.now()
    return
      adjustedSpins
      .filter { $0.airtime <= now && $0.endtime > now }
      .sorted { $0.airtime > $1.airtime }
      .first
  }

  private func adjustedSpins(offsetTimeInterval: TimeInterval? = nil) -> [Spin] {
    guard let offsetTimeInterval else { return spins }
    return spins.map { $0.withOffset(offsetTimeInterval) }
  }
}

extension Schedule {
  public static let mock: Schedule = {
    let url = Bundle.module.url(
      forResource: "MockSchedule", withExtension: "json", subdirectory: "MockData")!
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
