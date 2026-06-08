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

  /// When set, every call throws this error (simulating a transport-level
  /// failure such as a `URLError`) instead of returning a response.
  var errorToThrow: Error?

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestCallCount += 1
    lastRequest = request

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
