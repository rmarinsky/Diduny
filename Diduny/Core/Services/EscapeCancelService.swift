import AppKit
import Foundation

/// Service to handle double-escape cancellation during recording.
/// First escape shows a confirmation notification, second escape within threshold cancels recording.
@MainActor
final class EscapeCancelService: ObservableObject {
    static let shared = EscapeCancelService()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var firstPressTime: Date?
    private let secondPressThreshold: TimeInterval = 1.5
    private var timeoutTask: Task<Void, Never>?
    private var isActive = false

    /// Called when recording should be cancelled (after double-escape confirmed)
    var onCancel: (() -> Void)?

    /// Called on first escape to show confirmation notification
    var onFirstEscape: (() -> Void)?

    private init() {}

    /// Activate escape monitoring (call when recording starts)
    func activate() {
        guard !isActive else { return }
        isActive = true
        firstPressTime = nil

        // Monitor keyDown events globally for Escape key
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
        }

        // Also monitor locally when app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
            // Don't consume the event - let it propagate
            return event
        }

        Log.app.debug("Escape cancel handler activated")
    }

    /// Deactivate escape monitoring (call when recording stops)
    func deactivate() {
        isActive = false

        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        firstPressTime = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        Log.app.debug("Escape cancel handler deactivated")
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isActive else { return }

        // Check for Escape key (keyCode 53)
        guard event.keyCode == 53 else { return }

        let now = Date()

        if let firstTime = firstPressTime,
           now.timeIntervalSince(firstTime) <= secondPressThreshold
        {
            // Second press within threshold - cancel recording
            Log.app.info("Double-escape detected - cancelling recording")
            firstPressTime = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            onCancel?()

        } else {
            // First press - show notification and wait
            firstPressTime = now
            Log.app.debug("First escape press - waiting for confirmation")

            // Play subtle sound for feedback
            NSSound(named: NSSound.Name("Tink"))?.play()

            // Notify to show confirmation message
            onFirstEscape?()

            // Set timeout to reset
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.secondPressThreshold ?? 1.5))
                guard !Task.isCancelled else { return }
                self?.firstPressTime = nil
            }
        }
    }
}
