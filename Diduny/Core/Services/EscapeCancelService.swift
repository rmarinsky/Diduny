import AppKit
import Foundation

/// Service to handle double-press cancellation shortcut during recording.
/// Press Escape 2x or 3x within threshold to cancel active recording.
@MainActor
final class EscapeCancelService: ObservableObject {
    static let shared = EscapeCancelService()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastPressTime: Date?
    private var consecutivePressCount = 0
    private let pressThreshold: TimeInterval = 1.5
    private var timeoutTask: Task<Void, Never>?
    private var isActive = false

    /// Called when recording should be cancelled (after required press count confirmed)
    var onCancel: (() -> Void)?

    /// Called on intermediate Escape presses so UI can explain how many are left.
    var onProgressEscape: ((Int, Int) -> Void)?

    private init() {}

    /// Activate shortcut monitoring (call when recording starts)
    func activate() {
        guard !isActive else { return }
        isActive = true
        resetPressState()

        // Monitor keyDown events globally.
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

        Log.app.debug("Cancel shortcut handler activated")
    }

    /// Deactivate shortcut monitoring (call when recording stops)
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

        resetPressState()
        onCancel = nil
        onProgressEscape = nil

        Log.app.debug("Cancel shortcut handler deactivated")
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isActive else { return }
        guard SettingsStorage.shared.escapeCancelEnabled else {
            resetPressState()
            return
        }
        guard event.type == .keyDown, !event.isARepeat, event.keyCode == 53 else { return }

        let now = Date()
        let requiredPressCount = SettingsStorage.shared.escapeCancelPressCount

        if let lastPressTime, now.timeIntervalSince(lastPressTime) <= pressThreshold {
            consecutivePressCount += 1
        } else {
            consecutivePressCount = 1
        }
        self.lastPressTime = now

        if consecutivePressCount >= requiredPressCount {
            Log.app.info("\(requiredPressCount)x Escape detected - cancelling recording")
            resetPressState()
            onCancel?()
        } else {
            Log.app.debug("Escape press \(self.consecutivePressCount)/\(requiredPressCount) - waiting for confirmation")
            NSSound(named: NSSound.Name("Tink"))?.play()
            onProgressEscape?(self.consecutivePressCount, requiredPressCount)
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.pressThreshold ?? 1.5))
                guard !Task.isCancelled else { return }
                self?.resetPressState()
            }
        }
    }

    private func resetPressState() {
        lastPressTime = nil
        consecutivePressCount = 0
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
