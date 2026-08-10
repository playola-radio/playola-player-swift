import Foundation

/// Maps the wall-clock rolling schedule onto the mixed-output **sample timeline** for the sample-buffer
/// render path (Phase 5).
///
/// One `TimelineMapper` is created per play generation. Output frame 0 is the station-time origin
/// (`anchorDate`); every subsequent output frame advances by `1 / sampleRate` seconds of station time.
/// A spin that airs at some wall-clock `Date` therefore begins at a specific **output frame index**, and
/// the mixer asks, for each output frame it is producing, which spins are active and at what offset.
///
///     output frame N  ⇄  wall-clock date = anchorDate + N/sampleRate − scheduleOffset
///     spin start frame = frame(for: spin.airtime)
///
/// A spin already airing when the station starts has a **negative** start frame (it began before the
/// timeline origin); the mixer/mid-file-join reads that spin's file from the corresponding positive
/// offset. `scheduleOffset` shifts the whole timeline for time-shifted playback ("play from a past date").
///
/// Pure value type — no CoreMedia, no AVFoundation — so schedule→frame mapping is unit-testable on any
/// platform. CMTime conversion for the renderer lives in the sink layer, not here.
struct TimelineMapper: Equatable, Sendable {
  /// Wall-clock instant presented at output frame 0 (station-time origin for this play generation).
  let anchorDate: Date
  /// Additive station-time shift (seconds) for time-shifted playback. 0 for "play live from now".
  let scheduleOffset: TimeInterval
  /// Mixed-output sample rate (frames per second).
  let sampleRate: Double

  /// Output frame index at which a given wall-clock `date` is presented on the mix timeline.
  /// Negative for dates before the anchor (e.g. a spin already airing at station start).
  func frame(for date: Date) -> Int64 {
    let stationSeconds = date.timeIntervalSince(anchorDate) + scheduleOffset
    return Int64((stationSeconds * sampleRate).rounded())
  }

  /// Inverse of `frame(for:)`: the wall-clock date presented at a given output frame.
  func date(forFrame frame: Int64) -> Date {
    let stationSeconds = Double(frame) / sampleRate - scheduleOffset
    return anchorDate.addingTimeInterval(stationSeconds)
  }
}
