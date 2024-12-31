//
//  Test.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Foundation
import Testing
@testable import PlayolaPlayer

struct Test {
  var schedule: Schedule = .mock

  @Test("'current' advances to the correct point in the schedule.")
  func test() throws {
      let dateProviderMock = DateProviderMock(mockDate: schedule.spins[3].endtime + TimeInterval(1))
      let newSchedule = Schedule(
        stationId: schedule.stationId,
        spins: schedule.spins,
        dateProvider: dateProviderMock)
      #expect(newSchedule.current.count == newSchedule.spins.count - 4)
      #expect(newSchedule.current[0] == newSchedule.spins[4])
    }

}
