//  RenderSeamFakes.swift
//  PlayolaPlayer
//
//  Deterministic fakes for the Phase 5 render seam (PHASE_5_PLAN §6). They keep
//  CoreMedia out of the pipeline's unit tests: record calls, toggle readiness,
//  and fire boundary observers on demand.

import CoreMedia
import Foundation

@testable import PlayolaPlayer

/// Deterministic clock for the render-seam tests (the PlayolaCoreTests `DateProviderMock` is in a
/// different test target).
final class DateProviderMock: DateProviderProtocol, @unchecked Sendable {
  private var date: Date
  init(mockDate: Date) { self.date = mockDate }
  func now() -> Date { date }
  func setMockDate(_ date: Date) { self.date = date }
}

final class FakeSampleBufferRenderer: SampleBufferRendering, @unchecked Sendable {
  private(set) var enqueued: [RenderBuffer] = []
  private(set) var flushCount = 0
  private(set) var stopRequestCount = 0
  var isReadyForMoreMediaData = true
  private var requestBlock: (@Sendable () -> Void)?

  func enqueue(_ buffer: RenderBuffer) {
    enqueued.append(buffer)
  }

  func flush() {
    flushCount += 1
  }

  func requestMediaDataWhenReady(
    on queue: DispatchQueue, using block: @escaping @Sendable () -> Void
  ) {
    requestBlock = block
  }

  func stopRequestingMediaData() {
    stopRequestCount += 1
    requestBlock = nil
  }

  /// Simulate the media queue pulling: invoke the registered fill block once.
  func pump() {
    requestBlock?()
  }
}

final class FakeRenderSynchronizer: RenderSynchronizing, @unchecked Sendable {
  private(set) var setRateCalls: [(rate: Float, time: CMTime)] = []
  var currentTime: CMTime = .zero
  var rate: Float = 1.0

  private var observers: [(times: [CMTime], block: @Sendable () -> Void)] = []

  /// Every boundary time installed via `addBoundaryObserver` (flattened, in install order).
  var installedBoundaryTimes: [CMTime] { observers.flatMap(\.times) }

  func setRate(_ rate: Float, time: CMTime) {
    setRateCalls.append((rate, time))
    self.rate = rate
  }

  func addBoundaryObserver(
    forTimes times: [CMTime], _ block: @escaping @Sendable () -> Void
  ) -> Any {
    let token = UUID()
    observers.append((times, block))
    return token
  }

  func removeObserver(_ token: Any) {
    // No-op for the fake; tests fire observers explicitly via `fireBoundary`.
  }

  /// Fire every registered boundary observer once (simulate the timebase crossing a boundary).
  func fireBoundary() {
    for observer in observers { observer.block() }
  }
}
