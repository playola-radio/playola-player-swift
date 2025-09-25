//
//  DateProvider.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public final class DateProvider: Sendable, DateProviderProtocol {
  public static let shared: DateProvider = {
    let instance = DateProvider()
    return instance
  }()

  public func now() -> Date {
    return Date()
  }
}

public protocol DateProviderProtocol: Sendable {
  func now() -> Date
}
