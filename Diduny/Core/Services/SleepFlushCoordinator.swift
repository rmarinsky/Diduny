import AppKit
import Foundation
import os

// MARK: - SleepFlushCoordinator

/// Coordinates flush-on-sleep for active recordings.
///
/// Registered as an observer of `NSWorkspace.willSleepNotification` and
/// `NSWorkspace.didWakeNotification`.
///
/// Per ADR-0009 §D4b: handlers are registered with `queue: nil` so notifications
/// are delivered synchronously on the posting thread (a Foundation background thread,
/// NOT MainActor). The `flushCurrentChunk` closure is called on that background thread
/// and must return before the notification handler returns — the system's willSleep ACK
/// is implicit in the handler return. Do NOT dispatch to MainActor inside the handler
/// (that hop is asynchronous and the system won't wait for it).
///
/// **Threading danger (why @MainActor is absent):**
/// `NSWorkspace.willSleepNotification` is posted on a background system thread, not the
/// main thread. If this class were `@MainActor`, the `@objc` methods would need a hop to
/// the main actor, but that hop is asynchronous — the notification handler would return
/// before the hop completes and we would lose the sync flush guarantee. The class is
/// therefore NOT `@MainActor`. Callers that need main-actor work (e.g., updating AppState)
/// must dispatch explicitly inside `onWake` using `DispatchQueue.main.async`.
final class SleepFlushCoordinator {

    // MARK: - Public Closures

    /// Called synchronously on the willSleep notification thread.
    /// Must complete (or time out) within ~250 ms.
    /// Returns `true` if the flush completed cleanly, `false` on timeout or error.
    /// Nil means no active recording — treated as success.
    var flushCurrentChunk: (() -> Bool)?

    /// Called on the didWake notification thread (also a background thread).
    /// Receivers should dispatch to main if they need to update UI.
    var onWake: (() -> Void)?

    // MARK: - Init

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self,
            selector: #selector(handleWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Handlers

    /// Runs synchronously on the power-management background thread.
    /// The system does NOT proceed to sleep until this method returns.
    @objc private func handleWillSleep(_ note: Notification) {
        Log.recording.info("[Sleep] willSleepNotification received — flushing active recording")
        let start = Date()
        let ok = flushCurrentChunk?() ?? true
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        Log.recording.info("[Sleep] flush completed=\(ok) elapsed=\(elapsed)ms")
    }

    /// Runs synchronously on the power-management background thread.
    @objc private func handleDidWake(_ note: Notification) {
        Log.recording.info("[Sleep] didWakeNotification received")
        onWake?()
    }
}
