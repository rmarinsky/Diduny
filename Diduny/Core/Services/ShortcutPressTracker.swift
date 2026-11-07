import Foundation

// MARK: - Time seams (test-plan 2.3)

/// Seconds on a clock that never jumps; only differences matter.
protocol MonotonicClock {
    var now: TimeInterval { get }
}

struct SystemClock: MonotonicClock {
    var now: TimeInterval {
        #if TEST_BUILD
            if let manual = UITestHarness.manualClock { return manual.now }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
}

protocol ScheduledWork: AnyObject {
    func cancel()
}

/// Runs `work` once after `delay`, on the main thread, unless cancelled first.
protocol DelayScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> any ScheduledWork
}

/// Production scheduler: a main-actor `Task.sleep`, as the services used before.
struct TaskDelayScheduler: DelayScheduler {
    private final class TaskWork: ScheduledWork {
        let task: Task<Void, Never>

        init(_ task: Task<Void, Never>) {
            self.task = task
        }

        func cancel() {
            task.cancel()
        }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> any ScheduledWork {
        let milliseconds = Int((delay * 1000).rounded())
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            work()
        }
        return TaskWork(task)
    }
}

// MARK: - Press counting

/// Counts repeated presses of one shortcut. A press joins the sequence when it comes less than
/// `window` after the previous press (strict). Shared by every Carbon hotkey row (plan 3.5).
struct PressCounter {
    /// Press-to-press window of every multi-press hotkey (test-plan 3.4).
    static let hotkeyWindow: TimeInterval = 0.35

    private(set) var lastPressAt: TimeInterval?
    private(set) var count = 0

    /// Returns `true` when this press completes `required` presses; the sequence then starts over.
    mutating func register(at time: TimeInterval, required: Int, window: TimeInterval = Self.hotkeyWindow) -> Bool {
        guard required > 1 else {
            reset()
            return true
        }

        if let lastPressAt, time - lastPressAt < window {
            count += 1
        } else {
            count = 1
        }
        lastPressAt = time

        guard count >= required else { return false }
        reset()
        return true
    }

    mutating func reset() {
        lastPressAt = nil
        count = 0
    }
}
