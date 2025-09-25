//
//  JSONDecoderWithIsoFull.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//

import Foundation

// @unchecked Sendable baceuase JSONDecoder is currently also @unchecked Sendable
public class JSONDecoderWithIsoFull: JSONDecoder, @unchecked Sendable {
  override public init() {
    super.init()
    dateDecodingStrategy = .formatted(.iso8601Full)
  }
}
