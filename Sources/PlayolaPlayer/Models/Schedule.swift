//
//  Schedule.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Foundation

public struct Schedule: Sendable {
  public let id = UUID()
  public let stationId: String
  public let spins: [Spin]
  public let dateProvider: DateProvider

public init(stationId: String, spins: [Spin], dateProvider: DateProvider = .shared) {
    self.stationId = stationId
    self.spins = spins
    self.dateProvider = dateProvider
  }

  public var current: [Spin] {
    let now = dateProvider.now()
    return spins.filter({$0.endtime > now}).sorted { $0.airtime < $1.airtime }
  }

  public var nowPlaying: Spin? {
    let now = dateProvider.now()
    return spins.filter({ $0.isPlaying }).last
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

extension Schedule: Equatable, Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  public static func == (lhs: Schedule, rhs: Schedule) -> Bool {
    return lhs.id == rhs.id
  }
}
