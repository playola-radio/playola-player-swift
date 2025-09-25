//
//  DateProviderMock.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/30/24.
//

import Foundation
import os

@testable import PlayolaPlayer

final class DateProviderMock: DateProviderProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var _mockDate: Date

    init(mockDate: Date = Date()) {
        _mockDate = mockDate
    }

    func now() -> Date {
        lock.withLock { _mockDate }
    }

    func setMockDate(_ date: Date) {
        lock.withLock { _mockDate = date }
    }
}
