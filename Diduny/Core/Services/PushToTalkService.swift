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

    // Multi-tap detection for toggle mode
    private var lastToggleTapTime: TimeInterval?
    private var consecutiveToggleTapCount = 0
    private let toggleTapThreshold: TimeInterval = 0.3
    private var isHandsFreeMode = false

    var selectedKey: PushToTalkKey = .none
    var toggleTapCount: Int = 3
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// Called when recording should toggle (for hands-free mode)
    var onToggle: (() -> Void)?

    /// Whether toggle mode is enabled (from settings)
    private var isToggleModeEnabled: Bool {
        SettingsStorage.shared.handsFreeModeEnabled
    }

    func start() {
        stop()

        guard selectedKey != .none else { return }

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

        Log.app.info("Started monitoring for \(self.selectedKey.displayName)")
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
        isHandsFreeMode = false
        lastToggleTapTime = nil
        consecutiveToggleTapCount = 0
        Log.app.info("Stopped monitoring")
    }

    /// Reset hands-free mode (call when recording is cancelled externally)
    func resetHandsFreeMode() {
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
        handleModifierKeyEvent(isPressed: isPressed, eventTime: eventTime)
    }

    private func handleCapsLockEvent(keyCode: UInt16, eventTime: TimeInterval) {
        guard keyCode == 57 else { return }

        if isToggleModeEnabled {
            // Caps Lock in toggle mode: toggle after the configured number of taps
            if !isKeyPressed {
                isKeyPressed = true
                handleToggleTap(eventTime: eventTime, keyLabel: "Caps Lock")
            } else {
                isKeyPressed = false
            }
        } else {
            // Standard behavior
            if !isKeyPressed {
                isKeyPressed = true
                Log.app.info("Caps Lock pressed - starting recording")
                onKeyDown?()
            } else {
                isKeyPressed = false
                Log.app.info("Caps Lock released - stopping recording")
                onKeyUp?()
            }
        }
    }

    private func handleModifierKeyEvent(isPressed: Bool, eventTime: TimeInterval) {
        guard isPressed != isKeyPressed else { return }

        if isPressed {
            // Key down
            isKeyPressed = true

            // Check for configured tap count (toggle mode enabled)
            if isToggleModeEnabled {
                handleToggleTap(eventTime: eventTime, keyLabel: selectedKey.displayName)
                return
            }

            // Hold-to-record mode: start recording on key down
            Log.app.info("\(self.selectedKey.displayName) pressed - starting recording")
            onKeyDown?()

        } else {
            // Key up
            isKeyPressed = false

            if isToggleModeEnabled {
                // In toggle mode: don't stop on release
                return
            }

            // Hold-to-record mode: stop recording on release
            Log.app.info("\(self.selectedKey.displayName) released - stopping recording")
            onKeyUp?()
        }
    }

    private func handleToggleTap(eventTime: TimeInterval, keyLabel: String) {
        let requiredTapCount = sanitizedToggleTapCount

        if let lastTap = lastToggleTapTime, eventTime - lastTap < toggleTapThreshold {
            consecutiveToggleTapCount += 1
        } else {
            consecutiveToggleTapCount = 1
        }
        lastToggleTapTime = eventTime

        guard consecutiveToggleTapCount >= requiredTapCount else { return }

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
    }

    private var sanitizedToggleTapCount: Int {
        min(max(toggleTapCount, 2), 3)
    }

    private func isKeyCurrentlyPressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch selectedKey {
        case .none:
            return false
        case .capsLock:
            return keyCode == 57 && flags.contains(.capsLock)
        case .leftShift:
            return keyCode == 56 && flags.contains(.shift)
        case .leftOption:
            return keyCode == 58 && flags.contains(.option)
        case .leftCommand:
            return keyCode == 55 && flags.contains(.command)
        case .leftControl:
            return keyCode == 59 && flags.contains(.control)
        case .rightShift:
            return keyCode == 60 && flags.contains(.shift)
        case .rightOption:
            return keyCode == 61 && flags.contains(.option)
        case .rightCommand:
            return keyCode == 54 && flags.contains(.command)
        case .rightControl:
            return keyCode == 62 && flags.contains(.control)
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
