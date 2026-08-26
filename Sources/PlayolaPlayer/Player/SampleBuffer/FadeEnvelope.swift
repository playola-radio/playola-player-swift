import Foundation
import PlayolaCore

/// Per-position playback gain for a single spin on the sample-buffer render path.
///
/// This reproduces the **legacy engine's fade behaviour**: the legacy path drives an AU volume
/// parameter with a ~1.5 s *linear ramp* from the previous level to each fade's target, anchored at
/// `fade.atMS` in the file's own timeline (see `SpinPlayer.scheduleFades`). The fade targets and the
/// starting level are taken from the SAME source of truth the legacy path uses — `Spin.startingVolume`
/// and `Spin.fades` (the data behind `Spin.volumeAt*`) — never a reimplemented curve.
///
/// The envelope is a pure function of position within the spin (time since `airtime`), so mid-file
/// join needs no special handling: the mixer simply evaluates the gain at the join position, and the
/// continuous ramp yields a smooth value with no discontinuity.
///
/// KNOWN DIVERGENCE FROM LEGACY AT A MID-FILE JOIN (deliberate; flag for the device A/B): when the
/// legacy path *starts* mid-file it sets the initial volume to the stepwise `Spin.volumeAt(ms)` (3 s
/// look-ahead) and drops fades before the join (`SpinPlayer.setInitialVolume` / `scheduleFades`). This
/// envelope instead reports the continuous ramp value at the join position — e.g. joining 5.5 s into a
/// spin with a fade at 5.0 s→0.2 yields ~0.73 here vs 0.2 in legacy. Chosen for a jump-free join; if
/// strict cross-backend join parity is required, add a join-aware initial level and test it.
///
/// At *plateau* positions — before the first fade, and once a ramp has completed — this equals the
/// stepwise `Spin.volumeAtMS`; between them it interpolates linearly over the ramp window.
struct FadeEnvelope: Sendable, Equatable {
  /// Fade ramp duration, matching the legacy `SpinPlayer.Constants.fadeDuration` (1.5 s).
  static let rampDurationMS: Double = 1_500

  private let startingVolume: Float
  /// Fades sorted ascending by `atMS` (as `Spin` guarantees).
  private let fades: [Fade]

  init(spin: Spin) {
    self.startingVolume = spin.startingVolume
    self.fades = spin.fades  // already sorted by Spin's initializer
  }

  /// Playback gain at `ms` milliseconds since the spin's airtime.
  func gain(atMS ms: Int) -> Float {
    gain(atSeconds: Double(ms) / 1_000)
  }

  /// Playback gain at `seconds` since the spin's airtime.
  func gain(atSeconds seconds: Double) -> Float {
    let positionMS = seconds * 1_000
    var level = startingVolume  // plateau carried into the next ramp

    for (index, fade) in fades.enumerated() {
      let rampStart = Double(fade.atMS)
      // A later fade preempts this ramp (fades < rampDuration apart): stop it where the next begins
      // and carry the level actually reached, like the legacy AU ramp (which ramps from the CURRENT
      // value) — otherwise the gain jumps discontinuously at the preempted ramp's nominal end.
      let nextStart =
        index + 1 < fades.count ? Double(fades[index + 1].atMS) : Double.infinity
      let rampEnd = min(rampStart + Self.rampDurationMS, nextStart)

      if positionMS < rampStart {
        // Before this ramp begins: hold the current plateau.
        return level
      } else if positionMS < rampEnd {
        // Within the ramp: linear interpolate from the plateau to the target (full-ramp slope).
        let progress = Float((positionMS - rampStart) / Self.rampDurationMS)
        return level + progress * (fade.toVolume - level)
      }
      // Ramp ended: a COMPLETED ramp lands exactly on its target (float-exact, matching
      // Spin.volumeAtMS at plateaus); a PREEMPTED one carries the level actually reached.
      let reached = Float(min(1, (rampEnd - rampStart) / Self.rampDurationMS))
      level = reached >= 1 ? fade.toVolume : level + reached * (fade.toVolume - level)
    }

    return level
  }

  /// Playback gain at a given output-frame offset into the spin, for the mixer's hot path.
  func gain(atFrame frameOffset: Int64, sampleRate: Double) -> Float {
    gain(atSeconds: Double(frameOffset) / sampleRate)
  }
}
