//
//  PlayolaNetworkLoggingSession.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 6/4/26.
//
import Foundation

/// A ``URLSessionProtocol`` wrapper that times each call and emits a
/// ``PlayolaNetworkLogEvent`` to ``PlayolaNetworkLogger/handler`` on both
/// success and thrown error.
///
/// It is a transparent pass-through: it returns exactly what the wrapped
/// session returns and rethrows any error unchanged — it never swallows or
/// alters the result. When ``PlayolaNetworkLogger/handler`` is `nil` no event
/// is built and the wrapper adds negligible overhead.
public struct PlayolaNetworkLoggingSession: URLSessionProtocol {
  private let base: URLSessionProtocol
  private let dateProvider: DateProviderProtocol

  public init(
    wrapping base: URLSessionProtocol,
    dateProvider: DateProviderProtocol = DateProvider.shared
  ) {
    self.base = base
    self.dateProvider = dateProvider
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let start = dateProvider.now()
    do {
      let (data, response) = try await base.data(for: request)
      emit(request: request, start: start, data: data, response: response, error: nil)
      return (data, response)
    } catch {
      emit(request: request, start: start, data: nil, response: nil, error: error)
      throw error
    }
  }

  private func emit(
    request: URLRequest,
    start: Date,
    data: Data?,
    response: URLResponse?,
    error: Error?
  ) {
    guard let handler = PlayolaNetworkLogger.handler else { return }
    let durationMS = Int(dateProvider.now().timeIntervalSince(start) * 1000)
    let event = PlayolaNetworkLogEvent(
      timestamp: start,
      method: request.httpMethod ?? "GET",
      url: request.url,
      requestHeaders: request.allHTTPHeaderFields ?? [:],
      requestBody: request.httpBody,
      statusCode: (response as? HTTPURLResponse)?.statusCode,
      responseBody: data,
      durationMS: durationMS,
      errorDescription: error?.localizedDescription
    )
    handler(event)
  }
}
