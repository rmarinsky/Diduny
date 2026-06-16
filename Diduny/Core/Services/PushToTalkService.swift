import AppKit
import Carbon
import Foundation
import os

final class PushToTalkService: PushToTalkServiceProtocol {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isKeyPressed = false
    private var isReady = false
    private var startTime: Date?
    private var pendingHoldStartTask: Task<Void, Never>?
    private var hasStartedAfterHold = false
    private var sanitizedHoldStartDelaySeconds: TimeInterval = 1.2

    // Multi-tap detection for toggle mode
    private var lastToggleTapTime: TimeInterval?
    private var consecutiveToggleTapCount = 0
    private let toggleTapThreshold: TimeInterval = 0.3
    private var isHandsFreeMode = false

    var selectedKey: PushToTalkKey = .none
    var holdModeEnabled = true
    var toggleModeEnabled = false
    var toggleTapCount: Int = 3
    var holdStartDelaySeconds: TimeInterval {
        get { sanitizedHoldStartDelaySeconds }
        set { sanitizedHoldStartDelaySeconds = Self.sanitizedHoldStartDelaySeconds(newValue) }
    }

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// Called when recording should toggle (for hands-free mode)
    var onToggle: (() -> Void)?

    func start() {
        stop()

        guard selectedKey != .none, holdModeEnabled || toggleModeEnabled else { return }

        // Mark not ready initially - ignore events for first 0.5 seconds
        isReady = false
        startTime = Date()
        isHandsFreeMode = false
        lastToggleTapTime = nil
        consecutiveToggleTapCount = 0

        // Monitor flags changed events globally
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Also monitor locally when app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // Become ready after cooldown
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.isReady = true
            Log.app.info("Push-to-talk ready for \(self?.selectedKey.displayName ?? "unknown")")
        }

        let selectedKeyLabel = selectedKey.displayName
        Log.app.info("Started monitoring for \(selectedKeyLabel)")
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isKeyPressed = false
        isReady = false
        startTime = nil
        cancelPendingHoldStart()
        hasStartedAfterHold = false
        isHandsFreeMode = false
        lastToggleTapTime = nil
        consecutiveToggleTapCount = 0
        Log.app.info("Stopped monitoring")
    }

    /// Reset hands-free mode (call when recording is cancelled externally)
    func resetHandsFreeMode() {
        if !hasStartedAfterHold {
            cancelPendingHoldStart()
        }
        if !isKeyPressed {
            hasStartedAfterHold = false
        }
        isHandsFreeMode = false
        lastToggleTapTime = nil
        consecutiveToggleTapCount = 0
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Ignore events during cooldown period
        guard isReady else { return }

        let flags = event.modifierFlags
        let keyCode = event.keyCode
        let eventTime = event.timestamp

        guard isCorrectKeyCode(keyCode) else { return }

        let isPressed = isKeyCurrentlyPressed(keyCode: keyCode, flags: flags)

        // Special handling for Caps Lock (toggle key by nature)
        if selectedKey == .capsLock {
            handleCapsLockEvent(keyCode: keyCode, eventTime: eventTime)
            return
        }

        // Handle modifier keys with configurable multi-tap detection
        processModifierKeyEvent(isPressed: isPressed, eventTime: eventTime)
    }

    private func handleCapsLockEvent(keyCode: UInt16, eventTime: TimeInterval) {
        guard keyCode == 57 else { return }

        if !isKeyPressed {
            processModifierKeyEvent(isPressed: true, eventTime: eventTime)
        } else {
            processModifierKeyEvent(isPressed: false, eventTime: eventTime)
        }
    }

    func processModifierKeyEvent(isPressed: Bool, eventTime: TimeInterval) {
        guard isPressed != isKeyPressed else { return }

        if isPressed {
            // Key down
            isKeyPressed = true
            hasStartedAfterHold = false

            let didToggle = toggleModeEnabled
                ? handleToggleTap(eventTime: eventTime, keyLabel: selectedKey.displayName)
                : false

            guard holdModeEnabled, !didToggle, !isHandsFreeMode else {
                return
            }

            // Hold-to-record mode: start recording only after the configured hold delay.
            scheduleHoldStart(keyLabel: selectedKey.displayName)

        } else {
            // Key up
            isKeyPressed = false
            cancelPendingHoldStart()

            guard holdModeEnabled else {
                return
            }

            guard hasStartedAfterHold else {
                let selectedKeyLabel = selectedKey.displayName
                Log.app.info("\(selectedKeyLabel) released before hold threshold - ignoring")
                return
            }

            // Hold-to-record mode: stop recording on release
            hasStartedAfterHold = false
            let selectedKeyLabel = selectedKey.displayName
            Log.app.info("\(selectedKeyLabel) released - stopping recording")
            onKeyUp?()
        }
    }

    private func scheduleHoldStart(keyLabel: String) {
        cancelPendingHoldStart()

        guard holdModeEnabled, !isHandsFreeMode else { return }

        let delay = holdStartDelaySeconds
        Log.app.info("\(keyLabel) pressed - waiting \(String(format: "%.1f", delay))s before starting recording")

        pendingHoldStartTask = Task { @MainActor [weak self] in
            let milliseconds = Int((delay * 1000).rounded())
            try? await Task.sleep(for: .milliseconds(milliseconds))

            guard !Task.isCancelled,
                  let self,
                  isKeyPressed,
                  !self.hasStartedAfterHold,
                  self.holdModeEnabled,
                  !self.isHandsFreeMode
            else { return }

            hasStartedAfterHold = true
            pendingHoldStartTask = nil
            Log.app.info("\(keyLabel) held for \(String(format: "%.1f", delay))s - starting recording")
            onKeyDown?()
        }
    }

    private func cancelPendingHoldStart() {
        pendingHoldStartTask?.cancel()
        pendingHoldStartTask = nil
    }

    @discardableResult
    private func handleToggleTap(eventTime: TimeInterval, keyLabel: String) -> Bool {
        let requiredTapCount = sanitizedToggleTapCount

        if let lastTap = lastToggleTapTime, eventTime - lastTap < toggleTapThreshold {
            consecutiveToggleTapCount += 1
        } else {
            consecutiveToggleTapCount = 1
        }
        lastToggleTapTime = eventTime

        guard consecutiveToggleTapCount >= requiredTapCount else { return false }

        consecutiveToggleTapCount = 0
        lastToggleTapTime = nil

        if isHandsFreeMode {
            isHandsFreeMode = false
            Log.app.info("\(requiredTapCount)x tap detected on \(keyLabel) - stopping recording (toggle off)")
        } else {
            isHandsFreeMode = true
            Log.app.info("\(requiredTapCount)x tap detected on \(keyLabel) - starting recording (toggle on)")
        }

        onToggle?()
        return true
    }

    private var sanitizedToggleTapCount: Int {
        min(max(toggleTapCount, 2), 3)
    }

    private static func sanitizedHoldStartDelaySeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 1.2 }
        let clamped = min(max(value, 0.5), 2.0)
        return (clamped * 10).rounded() / 10
    }

    // Device-dependent modifier masks (NX_DEVICE*KEYMASK). NSEvent.ModifierFlags
    // family bits (.shift/.option/.command/.control) don't tell left from right,
    // so a side-specific key can't detect its own key-up while the opposite-side
    // key is still held. These raw masks distinguish the physical side.
    private enum DeviceModifierMask {
        static let leftControl: UInt = 0x0000_0001
        static let leftShift: UInt = 0x0000_0002
        static let rightShift: UInt = 0x0000_0004
        static let leftCommand: UInt = 0x0000_0008
        static let rightCommand: UInt = 0x0000_0010
        static let leftOption: UInt = 0x0000_0020
        static let rightOption: UInt = 0x0000_0040
        static let rightControl: UInt = 0x0000_2000
    }

    private func isKeyCurrentlyPressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        func has(_ mask: UInt) -> Bool { flags.rawValue & mask != 0 }
        switch selectedKey {
        case .none:
            return false
        case .capsLock:
            // Caps Lock has no left/right variant; the family flag is correct here.
            return keyCode == 57 && flags.contains(.capsLock)
        case .leftShift:
            return keyCode == 56 && has(DeviceModifierMask.leftShift)
        case .leftOption:
            return keyCode == 58 && has(DeviceModifierMask.leftOption)
        case .leftCommand:
            return keyCode == 55 && has(DeviceModifierMask.leftCommand)
        case .leftControl:
            return keyCode == 59 && has(DeviceModifierMask.leftControl)
        case .rightShift:
            return keyCode == 60 && has(DeviceModifierMask.rightShift)
        case .rightOption:
            return keyCode == 61 && has(DeviceModifierMask.rightOption)
        case .rightCommand:
            return keyCode == 54 && has(DeviceModifierMask.rightCommand)
        case .rightControl:
            return keyCode == 62 && has(DeviceModifierMask.rightControl)
        }
    }

    private func isCorrectKeyCode(_ keyCode: UInt16) -> Bool {
        switch selectedKey {
        case .none:
            false
        case .capsLock:
            keyCode == 57
        case .leftShift:
            keyCode == 56
        case .leftOption:
            keyCode == 58
        case .leftCommand:
            keyCode == 55
        case .leftControl:
            keyCode == 59
        case .rightShift:
            keyCode == 60
        case .rightOption:
            keyCode == 61
        case .rightCommand:
            keyCode == 54
        case .rightControl:
            keyCode == 62
        }
    }
}
