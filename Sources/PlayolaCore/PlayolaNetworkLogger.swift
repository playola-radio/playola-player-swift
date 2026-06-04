//
//  PlayolaNetworkLogger.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 6/4/26.
//
import Foundation
import os

/// A single JSON API request/response observed by the library.
///
/// The library emits these raw — it does **not** redact, persist, or format
/// anything. A consuming app is responsible for redacting sensitive values
/// (e.g. `Authorization` headers) before storing or displaying them.
public struct PlayolaNetworkLogEvent: Sendable {
  /// The time the request started.
  public let timestamp: Date
  /// The HTTP method (e.g. `GET`, `POST`).
  public let method: String
  /// The request URL, if available.
  public let url: URL?
  /// All HTTP header fields sent with the request, unredacted.
  public let requestHeaders: [String: String]
  /// The raw request body, if any.
  public let requestBody: Data?
  /// The HTTP status code of the response, or `nil` if the request threw.
  public let statusCode: Int?
  /// The raw response body, or `nil` if the request threw.
  public let responseBody: Data?
  /// The wall-clock duration of the request in milliseconds.
  public let durationMS: Int?
  /// A description of the thrown error, or `nil` on success.
  public let errorDescription: String?

  public init(
    timestamp: Date,
    method: String,
    url: URL?,
    requestHeaders: [String: String],
    requestBody: Data?,
    statusCode: Int?,
    responseBody: Data?,
    durationMS: Int?,
    errorDescription: String?
  ) {
    self.timestamp = timestamp
    self.method = method
    self.url = url
    self.requestHeaders = requestHeaders
    self.requestBody = requestBody
    self.statusCode = statusCode
    self.responseBody = responseBody
    self.durationMS = durationMS
    self.errorDescription = errorDescription
  }
}

/// A logging seam for the library's JSON API traffic.
///
/// A consuming app sets ``handler`` at startup to observe the library's JSON
/// API calls (binary audio downloads are intentionally excluded). When
/// ``handler`` is `nil` (the default) no logging occurs and behavior and
/// performance are unchanged.
public enum PlayolaNetworkLogger {
  private static let _handler =
    OSAllocatedUnfairLock<(@Sendable (PlayolaNetworkLogEvent) -> Void)?>(initialState: nil)

  /// The handler invoked after each JSON API request completes.
  ///
  /// Set by the consuming app at startup. `nil` (the default) disables logging.
  /// Access is thread-safe.
  public static var handler: (@Sendable (PlayolaNetworkLogEvent) -> Void)? {
    get { _handler.withLock { $0 } }
    set { _handler.withLock { $0 = newValue } }
  }
}
