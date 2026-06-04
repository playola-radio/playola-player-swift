//
//  PlayolaNetworkLoggingSessionTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 6/4/26.
//
import Foundation
import PlayolaCore
import Testing
import os

@testable import PlayolaPlayer

/// Records events emitted to `PlayolaNetworkLogger.handler` in a thread-safe way.
private final class EventRecorder: Sendable {
  private let storage = OSAllocatedUnfairLock<[PlayolaNetworkLogEvent]>(initialState: [])
  func record(_ event: PlayolaNetworkLogEvent) { storage.withLock { $0.append(event) } }
  var events: [PlayolaNetworkLogEvent] { storage.withLock { $0 } }
}

/// A `DateProviderProtocol` that returns queued dates in order, falling back to
/// `Date()` once exhausted. Lets tests assert an exact `durationMS`.
private final class QueueDateProvider: Sendable, DateProviderProtocol {
  private let dates: OSAllocatedUnfairLock<[Date]>
  init(_ dates: [Date]) { self.dates = OSAllocatedUnfairLock(initialState: dates) }
  func now() -> Date {
    dates.withLock { $0.isEmpty ? Date() : $0.removeFirst() }
  }
}

/// A session that always throws, to verify error pass-through.
private struct ThrowingURLSession: URLSessionProtocol {
  let error: any Error & Sendable
  func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw error }
}

private struct StubError: Error, Equatable {
  let id: Int
}

@Suite("PlayolaNetworkLoggingSession", .serialized)
struct PlayolaNetworkLoggingSessionTests {

  @Test("Emits an event on success with correct method, url, status, and duration")
  func emitsEventOnSuccess() async throws {
    let recorder = EventRecorder()
    PlayolaNetworkLogger.handler = { recorder.record($0) }
    defer { PlayolaNetworkLogger.handler = nil }

    let url = URL(string: "https://test.com/v1/listeningSessions")!
    let requestBody = Data("{\"deviceId\":\"abc\"}".utf8)
    let responseBody = Data("{\"ok\":true}".utf8)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = requestBody
    request.addValue("Bearer secret-token", forHTTPHeaderField: "Authorization")

    let base = MockURLSession()
    base.addResponse(data: responseBody, statusCode: 200, url: url)

    let start = Date(timeIntervalSince1970: 1000)
    let session = PlayolaNetworkLoggingSession(
      wrapping: base,
      dateProvider: QueueDateProvider([start, start.addingTimeInterval(0.25)]))

    _ = try await session.data(for: request)

    let events = recorder.events
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.method == "POST")
    #expect(event.url == url)
    #expect(event.statusCode == 200)
    #expect(event.durationMS == 250)
    #expect(event.timestamp == start)
    #expect(event.requestBody == requestBody)
    #expect(event.responseBody == responseBody)
    #expect(event.requestHeaders["Authorization"] == "Bearer secret-token")
    #expect(event.errorDescription == nil)
  }

  @Test("Transparently passes through the wrapped session's data and response")
  func passesThroughData() async throws {
    PlayolaNetworkLogger.handler = nil

    let url = URL(string: "https://test.com/v1/stations/123/schedule")!
    let responseBody = Data("schedule-json".utf8)

    let base = MockURLSession()
    base.addResponse(data: responseBody, statusCode: 201, url: url)

    let session = PlayolaNetworkLoggingSession(wrapping: base)
    let (data, response) = try await session.data(for: URLRequest(url: url))

    #expect(data == responseBody)
    #expect((response as? HTTPURLResponse)?.statusCode == 201)
    #expect(base.requestCallCount == 1)
  }

  @Test("Emits an event on a thrown error and rethrows the original error unchanged")
  func emitsEventOnErrorAndRethrows() async throws {
    let recorder = EventRecorder()
    PlayolaNetworkLogger.handler = { recorder.record($0) }
    defer { PlayolaNetworkLogger.handler = nil }

    let url = URL(string: "https://test.com/v1/listeningSessions")!
    let thrownError = StubError(id: 42)
    let session = PlayolaNetworkLoggingSession(wrapping: ThrowingURLSession(error: thrownError))

    var caught: Error?
    do {
      _ = try await session.data(for: URLRequest(url: url))
    } catch {
      caught = error
    }

    #expect(caught as? StubError == thrownError)

    let events = recorder.events
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.statusCode == nil)
    #expect(event.responseBody == nil)
    #expect(event.errorDescription != nil)
    #expect(event.url == url)
  }

  @Test("Does not emit when no handler is set")
  func doesNotEmitWithoutHandler() async throws {
    PlayolaNetworkLogger.handler = nil

    let url = URL(string: "https://test.com")!
    let base = MockURLSession()
    base.addResponse(data: Data(), statusCode: 200, url: url)

    let session = PlayolaNetworkLoggingSession(wrapping: base)
    _ = try await session.data(for: URLRequest(url: url))

    #expect(base.requestCallCount == 1)
  }
}
