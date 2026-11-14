import CoreGraphics
import Foundation
import os

/// Owns a `CGEventTap` and runs it on a dedicated high-priority thread so the callback is serviced
/// independently of the main run loop. All cross-thread state (the Mach port + run loop) is guarded
/// by a lock; the C callback itself never touches this state (it routes through the controller).
final class AutoFixEventTap: @unchecked Sendable {
    private struct State {
        var eventTap: CFMachPort?
        var runLoop: CFRunLoop?
        var running = false
        /// False while the host paused the tap, so a system "tap disabled" notice does not resume it.
        var wantsEnabled = true
    }

    private let mask: CGEventMask
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var thread: Thread?
    private var userInfo: UnsafeMutableRawPointer?
    private var callback: CGEventTapCallBack?

    static let defaultThreadName = "ua.com.rmarinsky.papuga.autofix-tap"
    private let threadName: String

    init(mask: CGEventMask, threadName: String = AutoFixEventTap.defaultThreadName) {
        self.mask = mask
        self.threadName = threadName
    }

    var isActive: Bool {
        state.withLock { $0.running }
    }

    /// Spins up the tap thread. Returns false if a tap could not be created.
    @discardableResult
    func start(userInfo: UnsafeMutableRawPointer, callback: @escaping CGEventTapCallBack) -> Bool {
        guard thread == nil else { return state.withLock { $0.running } }
        self.userInfo = userInfo
        self.callback = callback

        // The tap is created on its own thread. Wait for that one attempt so the caller learns
        // whether it worked; before, this returned true without knowing.
        let attempted = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.threadMain(attempted: attempted)
        }
        thread.name = threadName
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        attempted.wait()
        guard state.withLock({ $0.running }) else {
            // The thread has already returned. Clear it so a later start() can try again.
            self.thread = nil
            self.userInfo = nil
            self.callback = nil
            return false
        }
        return true
    }

    private func threadMain(attempted: DispatchSemaphore) {
        guard let userInfo, let callback,
              let tap = CGEvent.tapCreate(
                  tap: .cgSessionEventTap,
                  place: .headInsertEventTap,
                  options: .defaultTap,
                  eventsOfInterest: mask,
                  callback: callback,
                  userInfo: userInfo
              )
        else {
            attempted.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state.withLock {
            $0.eventTap = tap
            $0.runLoop = runLoop
            $0.running = true
        }
        attempted.signal()

        CFRunLoopRun()

        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        state.withLock {
            $0.eventTap = nil
            $0.runLoop = nil
            $0.running = false
            $0.wantsEnabled = true
        }
    }

    /// Re-enable the tap after the system disabled it (timeout / user input). Safe from any thread.
    func reEnable() {
        state.withLock { state in
            if state.wantsEnabled, let tap = state.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    /// Disables or enables the live tap without tearing it down. A disabled tap sees no events.
    /// Safe from any thread.
    func setEnabled(_ enabled: Bool) {
        state.withLock { state in
            state.wantsEnabled = enabled
            if let tap = state.eventTap {
                CGEvent.tapEnable(tap: tap, enable: enabled)
            }
        }
    }

    func stop() {
        let runLoop: CFRunLoop? = state.withLock { state in
            if let tap = state.eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            return state.runLoop
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        thread = nil
        userInfo = nil
        callback = nil
    }
}
