//
//  MockUrlSession.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 7/10/25.
//
import Foundation

@testable import PlayolaPlayer

final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
  var responses: [(Data, URLResponse)] = []
  var requestCallCount = 0
  var lastRequest: URLRequest?
  /// Every requested URL in order, so tests can assert which endpoints were hit
  /// (e.g. that no `/end` was ever sent), not just the most recent one.
  var requestedURLs: [URL] = []

  /// When set, every call throws this error (simulating a transport-level
  /// failure such as a `URLError`) instead of returning a response.
  var errorToThrow: Error?

  /// Optional async hook invoked at the start of each `data(for:)`, before the
  /// response is returned. Lets a test suspend a specific request to assert
  /// ordering across concurrent callers (e.g. hold station A's POST in flight).
  var beforeResponse: (@Sendable (URLRequest) async -> Void)?

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestCallCount += 1
    lastRequest = request
    if let url = request.url { requestedURLs.append(url) }

    if let beforeResponse { await beforeResponse(request) }

    if let errorToThrow {
      throw errorToThrow
    }

    if responses.isEmpty {
      // Default successful response
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (Data(), response)
    }

    // Return the first response and remove it (FIFO)
    return responses.removeFirst()
  }

  func addResponse(data: Data = Data(), statusCode: Int, url: URL? = nil) {
    let response = HTTPURLResponse(
      url: url ?? URL(string: "https://test.com")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    responses.append((data, response))
  }
}
