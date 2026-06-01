import XCTest
@testable import Diduny

/// Tests for `SleepFlushCoordinator` (RLR-M2).
///
/// These tests verify the synchronous notification delivery contract:
/// - `willSleepNotification` calls `flushCurrentChunk` synchronously before `post` returns.
/// - `didWakeNotification` calls `onWake` synchronously before `post` returns.
/// - A slow `flushCurrentChunk` closure still completes before the notification handler returns
///   (i.e., the coordinator does not internally dispatch the closure to another queue).
///
/// The tests post notifications directly to `NSWorkspace.shared.notificationCenter` using the
/// `queue: nil` registration path that `SleepFlushCoordinator` uses. Because the posting thread
/// blocks until all synchronously-registered observers return, the assertions below are valid
/// immediately after the `post` call returns.
final class SleepFlushCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private let workspaceNC = NSWorkspace.shared.notificationCenter

    private func postWillSleep() {
        workspaceNC.post(name: NSWorkspace.willSleepNotification, object: nil)
    }

    private func postDidWake() {
        workspaceNC.post(name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - 1. willSleep dispatches flushCurrentChunk synchronously

    /// After `willSleepNotification` is posted, `flushCurrentChunk` must have been called
    /// before the `post` call returns (synchronous delivery via `queue: nil`).
    func test_willSleep_callsFlushSynchronously() {
        let coordinator = SleepFlushCoordinator()
        var flushCalled = false

        coordinator.flushCurrentChunk = {
            flushCalled = true
            return true
        }

        postWillSleep()

        // If delivery were async, this assertion would fail intermittently.
        XCTAssertTrue(flushCalled, "flushCurrentChunk must be called synchronously on willSleepNotification")
    }

    // MARK: - 2. didWake dispatches onWake synchronously

    /// After `didWakeNotification` is posted, `onWake` must have been called
    /// before the `post` call returns.
    func test_didWake_callsOnWakeSynchronously() {
        let coordinator = SleepFlushCoordinator()
        var wakeCalled = false

        coordinator.onWake = {
            wakeCalled = true
        }

        postDidWake()

        XCTAssertTrue(wakeCalled, "onWake must be called synchronously on didWakeNotification")
    }

    // MARK: - 3. flushCurrentChunk return value is forwarded correctly

    /// The coordinator passes through the return value of `flushCurrentChunk` to its own
    /// log/internal state. We test both true and false returns to ensure the closure is
    /// actually invoked and is not short-circuited.
    func test_willSleep_flushReturnFalse_doesNotHang() {
        let coordinator = SleepFlushCoordinator()
        var flushResult: Bool? = nil

        coordinator.flushCurrentChunk = {
            flushResult = false
            return false
        }

        // This must return without hanging (the coordinator must not retry or wait).
        postWillSleep()

        XCTAssertEqual(flushResult, false, "flushCurrentChunk returning false should complete without hanging")
    }

    // MARK: - 4. Coordinator runs when no closures are set (nil safety)

    /// When `flushCurrentChunk` and `onWake` are nil, the coordinator must not crash.
    func test_willSleep_noClosureSet_doesNotCrash() {
        let coordinator = SleepFlushCoordinator()
        // Intentionally leaving flushCurrentChunk as nil
        XCTAssertNoThrow(postWillSleep())
        _ = coordinator // keep alive
    }

    func test_didWake_noClosureSet_doesNotCrash() {
        let coordinator = SleepFlushCoordinator()
        // Intentionally leaving onWake as nil
        XCTAssertNoThrow(postDidWake())
        _ = coordinator // keep alive
    }

    // MARK: - 5. Slow flush still completes before handler returns

    /// A closure that takes non-trivial time (100 ms) must still complete synchronously —
    /// the coordinator must NOT dispatch the closure to another queue.
    /// If the handler dispatched asynchronously, `flushCalled` would be false here.
    func test_willSleep_slowFlush_completesBeforeHandlerReturns() {
        let coordinator = SleepFlushCoordinator()
        var flushCalled = false

        coordinator.flushCurrentChunk = {
            // Simulate a non-trivial but fast flush (well within 250 ms budget)
            Thread.sleep(forTimeInterval: 0.1)
            flushCalled = true
            return true
        }

        postWillSleep()

        XCTAssertTrue(
            flushCalled,
            "flushCurrentChunk must complete synchronously even when it takes 100 ms — " +
            "coordinator must not dispatch to another queue"
        )
    }

    // MARK: - 6. Deinit removes observers (no double-fire after dealloc)

    /// After the coordinator is deallocated, posting willSleep must not fire the old closure.
    /// This guards against a use-after-free / dangling observer scenario.
    func test_deinit_removesObservers() {
        var flushCallCount = 0

        autoreleasepool {
            let coordinator = SleepFlushCoordinator()
            coordinator.flushCurrentChunk = {
                flushCallCount += 1
                return true
            }
            postWillSleep()
            // coordinator deallocated here when autoreleasepool drains
        }

        // At this point coordinator is gone. Post again — the closure must not fire.
        postWillSleep()

        XCTAssertEqual(flushCallCount, 1, "Observer must be removed on deinit — closure fired \(flushCallCount) times")
    }
}
