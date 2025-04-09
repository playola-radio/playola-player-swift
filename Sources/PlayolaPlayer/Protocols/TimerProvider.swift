import Foundation

public protocol TimerProvider {
    func schedule(deadline: Date, repeating: TimeInterval, block: @escaping () -> Void) -> Timer
}

public extension TimerProvider {
    // Add convenience method with default repeating value
    func schedule(deadline: Date, block: @escaping () -> Void) -> Timer {
        schedule(deadline: deadline, repeating: 0, block: block)
    }
}

public class LiveTimerProvider: TimerProvider {
    public static let shared = LiveTimerProvider()

    public func schedule(deadline: Date, repeating: TimeInterval, block: @escaping () -> Void) -> Timer {
        let timer = Timer(fire: deadline, interval: repeating, repeats: false) { _ in
            block()
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

public class TestTimerProvider: TimerProvider {
    public var scheduledTimers: [(deadline: Date, timer: Timer, block: () -> Void)] = []

    public func schedule(deadline: Date, repeating: TimeInterval, block: @escaping () -> Void) -> Timer {
        let timer = Timer(fire: deadline, interval: repeating, repeats: false) { _ in
            block()
        }
        scheduledTimers.append((deadline: deadline, timer: timer, block: block))
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
