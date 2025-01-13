//
//  SpinTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/8/25.
//

import Foundation
import Testing
@testable import PlayolaPlayer

struct SpinTests {
  var spin: Spin = .mock
  let dateProviderMock = DateProviderMock()

  init() {
    spin.dateProvider = dateProviderMock
  }

  @Test("isPlaying returns false if .now is too early")
  func testIsPlaying_nowIsBeforeSpin() throws {
    dateProviderMock.mockDate = spin.airtime - TimeInterval(30)
    #expect(!spin.isPlaying)
  }

  @Test("isPlaying returns true if .now is between start and endTime")
  func testIsPlaying_nowIsDuringSpin() throws {
    dateProviderMock.mockDate = spin.airtime + TimeInterval(3)
    #expect(spin.isPlaying)
  }

  @Test("isPlaying returns false if .now is after endtime")
  func testIsPlaying_nowIsAfterSpin() throws {
    dateProviderMock.mockDate = spin.endtime + TimeInterval(30)
    #expect(!spin.isPlaying)
  }
}
