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

    // Hands-free mode tracking
    private var keyPressEventTime: TimeInterval?
    private let briefPressThreshold: TimeInterval = 0.5
    private var isHandsFreeMode = false

    var selectedKey: PushToTalkKey = .none
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// Called when recording should toggle (for hands-free mode)
    var onToggle: (() -> Void)?

    /// Whether hands-free mode is currently enabled (from settings)
    private var isHandsFreeModeEnabled: Bool {
        SettingsStorage.shared.handsFreeModeEnabled
    }

    func start() {
        stop()

        guard selectedKey != .none else { return }

        // Mark not ready initially - ignore events for first 0.5 seconds
        isReady = false
        startTime = Date()
        isHandsFreeMode = false
        keyPressEventTime = nil

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
        keyPressEventTime = nil
        Log.app.info("Stopped monitoring")
    }

    /// Reset hands-free mode (call when recording is cancelled externally)
    func resetHandsFreeMode() {
        isHandsFreeMode = false
        keyPressEventTime = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Ignore events during cooldown period
        guard isReady else { return }

        let flags = event.modifierFlags
        let keyCode = event.keyCode
        let eventTime = event.timestamp

        guard isCorrectKeyCode(keyCode) else { return }

        let isPressed = isKeyCurrentlyPressed(keyCode: keyCode, flags: flags)

        // Special handling for Caps Lock (toggle key)
        if selectedKey == .capsLock {
            handleCapsLockEvent(keyCode: keyCode, eventTime: eventTime)
            return
        }

        // Handle modifier keys with hands-free support
        handleModifierKeyEvent(isPressed: isPressed, eventTime: eventTime)
    }

    private func handleCapsLockEvent(keyCode: UInt16, eventTime _: TimeInterval) {
        guard keyCode == 57 else { return }

        if isHandsFreeModeEnabled {
            // Caps Lock in hands-free mode: each press toggles
            if !isKeyPressed {
                isKeyPressed = true
                Log.app.info("Caps Lock pressed - toggling recording")
                onToggle?()
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
            keyPressEventTime = eventTime

            if isHandsFreeModeEnabled, isHandsFreeMode {
                // In hands-free mode: toggle recording on key down
                isHandsFreeMode = false
                Log.app.info("Hands-free toggle - stopping recording")
                onToggle?()
                return
            }

            // Start recording on key down
            Log.app.info("\(self.selectedKey.displayName) pressed - starting recording")
            onKeyDown?()

        } else {
            // Key up
            isKeyPressed = false

            if isHandsFreeModeEnabled, let pressTime = keyPressEventTime {
                let pressDuration = eventTime - pressTime

                if pressDuration < briefPressThreshold {
                    // Brief press: enter hands-free mode
                    isHandsFreeMode = true
                    Log.app.info("Brief press detected (\(String(format: "%.2f", pressDuration))s) - entering hands-free mode")
                    // Don't stop recording - user will toggle with next press
                    return
                }
            }

            // Long press or hands-free disabled: stop recording
            Log.app.info("\(self.selectedKey.displayName) released - stopping recording")
            onKeyUp?()
            keyPressEventTime = nil
        }
    }

    private func isKeyCurrentlyPressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch selectedKey {
        case .none:
            return false
        case .capsLock:
            return keyCode == 57 && flags.contains(.capsLock)
        case .rightShift:
            return keyCode == 60 && flags.contains(.shift)
        case .rightOption:
            return keyCode == 61 && flags.contains(.option)
        }
    }

    private func isCorrectKeyCode(_ keyCode: UInt16) -> Bool {
        switch selectedKey {
        case .none:
            false
        case .capsLock:
            keyCode == 57
        case .rightShift:
            keyCode == 60
        case .rightOption:
            keyCode == 61
        }
    }
}
