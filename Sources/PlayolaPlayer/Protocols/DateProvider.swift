//
//  DateProvider.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public class DateProvider: Sendable {
  public static let shared: DateProvider = {
    let instance = DateProvider()
    return instance
  }()

  public func now() -> Date {
    return Date()
  }
}
