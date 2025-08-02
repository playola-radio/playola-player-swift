//
//  DateMock.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/30/24.
//

import Foundation

@testable import PlayolaPlayer

public class DateProviderMock: DateProvider {
  public var mockDate: Date!
  public init(mockDate: Date = .now) {
    self.mockDate = mockDate
  }
  override public func now() -> Date {
    return mockDate
  }
}
