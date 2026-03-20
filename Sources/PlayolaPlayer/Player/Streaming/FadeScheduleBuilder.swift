import Foundation
import PlayolaCore

public struct FadeStep: Sendable, Equatable {
  public let timeMS: Int
  public let volume: Float

  public init(timeMS: Int, volume: Float) {
    self.timeMS = timeMS
    self.volume = volume
  }
}

public enum FadeScheduleBuilder {
  public static let fadeDurationMS: Double = 1500
  public static let fadeSteps: Int = 48

  /// Expands a spin's fades into discrete interpolation steps.
  ///
  /// Each fade in the spin is expanded into `fadeSteps` evenly-spaced steps
  /// over `fadeDurationMS` milliseconds, linearly interpolating from the previous
  /// volume level to the fade's target volume.
  ///
  /// Example: A fade at 30000ms from 1.0 to 0.0 with 48 steps over 1500ms produces
  /// 49 entries (steps 0...48) starting at timeMS=30000 and ending at timeMS=31500.
  public static func buildFadeSchedule(
    for spin: Spin,
    fadeDurationMS: Double = FadeScheduleBuilder.fadeDurationMS,
    fadeSteps: Int = FadeScheduleBuilder.fadeSteps
  ) -> [FadeStep] {
    let fades = spin.fades
    guard !fades.isEmpty else { return [] }

    var schedule: [FadeStep] = []
    let sortedFades = fades.sorted { $0.atMS < $1.atMS }
    var fromVolume = spin.startingVolume
    let stepDurationMS = fadeDurationMS / Double(fadeSteps)

    for fade in sortedFades {
      let toVolume = fade.toVolume
      let fadeStartMS = fade.atMS

      for step in 0...fadeSteps {
        let progress = Float(step) / Float(fadeSteps)
        let volume = fromVolume + (toVolume - fromVolume) * progress
        let timeMS = fadeStartMS + Int(Double(step) * stepDurationMS)
        schedule.append(FadeStep(timeMS: timeMS, volume: volume))
      }

      fromVolume = toVolume
    }

    return schedule
  }

  /// Returns the volume at a given millisecond position based on a fade schedule.
  ///
  /// Walks backward through the schedule to find the last step at or before `ms`.
  /// If `ms` is before all steps, returns `startingVolume`.
  public static func volumeAtMS(
    _ ms: Int,
    in schedule: [FadeStep],
    startingVolume: Float
  ) -> Float {
    var result = startingVolume

    for step in schedule {
      if step.timeMS <= ms {
        result = step.volume
      } else {
        break
      }
    }

    return result
  }

  /// Returns the index of the first fade step that hasn't been applied yet
  /// (i.e., the first step whose timeMS > currentMS).
  public static func firstUnprocessedIndex(
    in schedule: [FadeStep],
    afterMS currentMS: Int
  ) -> Int {
    for (index, step) in schedule.enumerated() {
      if step.timeMS > currentMS {
        return index
      }
    }
    return schedule.count
  }
}
