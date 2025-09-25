import Foundation

public struct ScheduledTimer {
    let deadline: Date
    let timer: Timer
    let block: () -> Void
}

public protocol TimerProvider: Sendable {
    func schedule(deadline: Date, repeating: TimeInterval, block: @escaping () -> Void) -> Timer
}

public extension TimerProvider {
    // Add convenience method with default repeating value
    func schedule(deadline: Date, block: @escaping () -> Void) -> Timer {
        schedule(deadline: deadline, repeating: 0, block: block)
    }
}

public final class LiveTimerProvider: TimerProvider {
    public static let shared = LiveTimerProvider()

    public func schedule(deadline: Date, repeating: TimeInterval, block: @escaping () -> Void)
        -> Timer
    {
        let timer = Timer(fire: deadline, interval: repeating, repeats: false) { _ in
            block()
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

// Unchecked because it's mutable, but only used in tests.
public final class TestTimerProvider: TimerProvider, @unchecked Sendable {
    public var scheduledTimers: [ScheduledTimer] = []

    public func schedule(deadline: Date, repeating: TimeInterval, block: @escaping () -> Void)
        -> Timer
    {
        let timer = Timer(fire: deadline, interval: repeating, repeats: false) { _ in
            block()
        }
        scheduledTimers.append(ScheduledTimer(deadline: deadline, timer: timer, block: block))
        return timer
    }

    public func executeNextTimer() {
        guard let nextTimer = scheduledTimers.min(by: { $0.deadline < $1.deadline }) else { return }
        nextTimer.block()
        nextTimer.timer.invalidate()
        scheduledTimers.removeAll { $0.timer === nextTimer.timer }
    }

    public func executeAllTimers() {
        while !scheduledTimers.isEmpty {
            executeNextTimer()
        }
    }
}

// Exploration of possible better mocking for later.
// struct TimerProviderStruct: Sendable {
//  var schedule: @Sendable (_ deadline: Date, _ repeating: TimeInterval,
//                         _ block: @Sendable @escaping () -> Void) -> Timer
// }
// extension TimerProviderStruct {
//  static var liveValue: Self {
//    return Self { deadline, repeating, block in
//      let timer = Timer(fire: deadline, interval: repeating, repeats: false) { _ in
//        block()
//      }
//      RunLoop.main.add(timer, forMode: .common)
//      return timer
//    }
//  }
// }
