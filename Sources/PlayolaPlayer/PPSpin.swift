//
//  PlayolaPlayerSpin.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public struct PPSpin {
  /// Used to Identify the spin when changes are made.
  var key: String!

  /// The remote audioFileURL
  var audioFileUrl: URL!
  var startTime: Date
  var beginFadeOutTime: Date
  var foregroundVolumeTime: Date?
  var backgroundVolumeTime: Date?
  var spinInfo: [String: Any]

  public init(key: String!,
              audioFileURL: URL!,
              startTime: Date,
              beginFadeOutTime: Date,
              foregroundVolumeTime: Date? = nil,
              backgroundVolumeTime: Date? = nil,
              spinInfo: [String : Any]) {
    self.key = key
    self.audioFileUrl = audioFileURL
    self.startTime = startTime
    self.beginFadeOutTime = beginFadeOutTime
    self.foregroundVolumeTime = foregroundVolumeTime
    self.backgroundVolumeTime = backgroundVolumeTime
    self.spinInfo = spinInfo
  }
}
