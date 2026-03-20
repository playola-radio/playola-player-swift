import Foundation
import Testing

@testable import PlayolaCore
@testable import PlayolaPlayer

struct FadeScheduleBuilderTests {

  // MARK: - buildFadeSchedule

  @Test("Empty fades array produces empty schedule")
  func testBuildFadeScheduleNoFades() {
    let spin = Spin.mockWith(fades: [])
    let schedule = FadeScheduleBuilder.buildFadeSchedule(for: spin)
    #expect(schedule.isEmpty)
  }

  @Test("Single fade produces fadeSteps+1 entries")
  func testBuildFadeScheduleSingleFade() {
    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [Fade(atMS: 30000, toVolume: 0.0)]
    )
    let schedule = FadeScheduleBuilder.buildFadeSchedule(for: spin)
    #expect(schedule.count == FadeScheduleBuilder.fadeSteps + 1)
  }

  @Test("Single fade starts at fade atMS and ends at atMS + fadeDuration")
  func testBuildFadeScheduleTiming() {
    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [Fade(atMS: 30000, toVolume: 0.0)]
    )
    let schedule = FadeScheduleBuilder.buildFadeSchedule(for: spin)

    #expect(schedule.first?.timeMS == 30000)
    #expect(schedule.last?.timeMS == 31500)
  }

  @Test("Single fade interpolates from startingVolume to target")
  func testBuildFadeScheduleInterpolation() {
    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [Fade(atMS: 10000, toVolume: 0.0)]
    )
    let schedule = FadeScheduleBuilder.buildFadeSchedule(for: spin)

    // First step should be startingVolume
    #expect(schedule.first!.volume == 1.0)
    // Last step should be target volume
    #expect(schedule.last!.volume == 0.0)
    // Midpoint should be approximately 0.5
    let midIndex = FadeScheduleBuilder.fadeSteps / 2
    #expect(abs(schedule[midIndex].volume - 0.5) < 0.02)
  }

  @Test("Multiple fades chain correctly")
  func testBuildFadeScheduleMultipleFades() {
    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [
        Fade(atMS: 10000, toVolume: 0.0),
        Fade(atMS: 20000, toVolume: 1.0),
      ]
    )
    let schedule = FadeScheduleBuilder.buildFadeSchedule(for: spin)
    let stepsPerFade = FadeScheduleBuilder.fadeSteps + 1

    #expect(schedule.count == stepsPerFade * 2)

    // First fade: 1.0 → 0.0
    #expect(schedule[0].volume == 1.0)
    #expect(schedule[stepsPerFade - 1].volume == 0.0)

    // Second fade: 0.0 → 1.0
    #expect(schedule[stepsPerFade].volume == 0.0)
    #expect(schedule[stepsPerFade * 2 - 1].volume == 1.0)
  }

  @Test("Fades are sorted by atMS regardless of input order")
  func testBuildFadeScheduleSortsInput() {
    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [
        Fade(atMS: 20000, toVolume: 1.0),
        Fade(atMS: 10000, toVolume: 0.0),
      ]
    )
    let schedule = FadeScheduleBuilder.buildFadeSchedule(for: spin)

    // First fade should start at 10000
    #expect(schedule.first?.timeMS == 10000)
  }

  @Test("Custom fade duration and steps are respected")
  func testBuildFadeScheduleCustomParams() {
    let spin = Spin.mockWith(
      startingVolume: 1.0,
      fades: [Fade(atMS: 5000, toVolume: 0.5)]
    )
    let schedule = FadeScheduleBuilder.buildFadeSchedule(
      for: spin, fadeDurationMS: 1000, fadeSteps: 10)

    #expect(schedule.count == 11)
    #expect(schedule.first?.timeMS == 5000)
    #expect(schedule.last?.timeMS == 6000)
  }

  // MARK: - volumeAtMS

  @Test("volumeAtMS before any fade returns startingVolume")
  func testVolumeAtMSBeforeFades() {
    let schedule = [
      FadeStep(timeMS: 10000, volume: 1.0),
      FadeStep(timeMS: 11500, volume: 0.0),
    ]
    let volume = FadeScheduleBuilder.volumeAtMS(5000, in: schedule, startingVolume: 0.8)
    #expect(volume == 0.8)
  }

  @Test("volumeAtMS at exact fade time returns that fade's volume")
  func testVolumeAtMSExactMatch() {
    let schedule = [
      FadeStep(timeMS: 10000, volume: 0.5),
      FadeStep(timeMS: 11000, volume: 0.0),
    ]
    let volume = FadeScheduleBuilder.volumeAtMS(10000, in: schedule, startingVolume: 1.0)
    #expect(volume == 0.5)
  }

  @Test("volumeAtMS after all fades returns last fade's volume")
  func testVolumeAtMSAfterAllFades() {
    let schedule = [
      FadeStep(timeMS: 10000, volume: 0.5),
      FadeStep(timeMS: 11500, volume: 0.0),
    ]
    let volume = FadeScheduleBuilder.volumeAtMS(20000, in: schedule, startingVolume: 1.0)
    #expect(volume == 0.0)
  }

  @Test("volumeAtMS with empty schedule returns startingVolume")
  func testVolumeAtMSEmptySchedule() {
    let volume = FadeScheduleBuilder.volumeAtMS(5000, in: [], startingVolume: 0.7)
    #expect(volume == 0.7)
  }

  // MARK: - firstUnprocessedIndex

  @Test("firstUnprocessedIndex returns 0 when all fades are in the future")
  func testFirstUnprocessedIndexAllFuture() {
    let schedule = [
      FadeStep(timeMS: 10000, volume: 0.5),
      FadeStep(timeMS: 11000, volume: 0.0),
    ]
    let index = FadeScheduleBuilder.firstUnprocessedIndex(in: schedule, afterMS: 5000)
    #expect(index == 0)
  }

  @Test("firstUnprocessedIndex returns count when all fades are past")
  func testFirstUnprocessedIndexAllPast() {
    let schedule = [
      FadeStep(timeMS: 10000, volume: 0.5),
      FadeStep(timeMS: 11000, volume: 0.0),
    ]
    let index = FadeScheduleBuilder.firstUnprocessedIndex(in: schedule, afterMS: 20000)
    #expect(index == schedule.count)
  }

  @Test("firstUnprocessedIndex returns correct index mid-schedule")
  func testFirstUnprocessedIndexMidSchedule() {
    let schedule = [
      FadeStep(timeMS: 10000, volume: 0.8),
      FadeStep(timeMS: 10500, volume: 0.5),
      FadeStep(timeMS: 11000, volume: 0.2),
      FadeStep(timeMS: 11500, volume: 0.0),
    ]
    let index = FadeScheduleBuilder.firstUnprocessedIndex(in: schedule, afterMS: 10500)
    #expect(index == 2)
  }
}
