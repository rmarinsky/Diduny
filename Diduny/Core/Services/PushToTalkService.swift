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

    // Double-tap detection for toggle mode
    private var lastKeyUpTime: TimeInterval?
    private let doubleTapThreshold: TimeInterval = 0.4
    private var isHandsFreeMode = false

    var selectedKey: PushToTalkKey = .none
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
        lastKeyUpTime = nil

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
        lastKeyUpTime = nil
        Log.app.info("Stopped monitoring")
    }

    /// Reset hands-free mode (call when recording is cancelled externally)
    func resetHandsFreeMode() {
        isHandsFreeMode = false
        lastKeyUpTime = nil
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
            handleCapsLockEvent(keyCode: keyCode)
            return
        }

        // Handle modifier keys with double-tap detection
        handleModifierKeyEvent(isPressed: isPressed, eventTime: eventTime)
    }

    private func handleCapsLockEvent(keyCode: UInt16) {
        guard keyCode == 57 else { return }

        if isToggleModeEnabled {
            // Caps Lock in toggle mode: each press toggles
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

            // Check for double-tap (toggle mode enabled)
            if isToggleModeEnabled {
                if let lastUp = lastKeyUpTime {
                    let timeSinceLastUp = eventTime - lastUp

                    if timeSinceLastUp < doubleTapThreshold {
                        // Double-tap detected
                        if isHandsFreeMode {
                            // Already in toggle mode: stop recording
                            isHandsFreeMode = false
                            Log.app.info("Double-tap detected - stopping recording (toggle off)")
                            onToggle?()
                        } else {
                            // Enter toggle mode: start recording
                            isHandsFreeMode = true
                            Log.app.info("Double-tap detected - starting recording (toggle on)")
                            onToggle?()
                        }
                    }
                    // Single tap in toggle mode: do nothing
                }
                // First tap or single tap: do nothing, wait for potential double-tap
                return
            }

            // Hold-to-record mode: start recording on key down
            Log.app.info("\(self.selectedKey.displayName) pressed - starting recording")
            onKeyDown?()

        } else {
            // Key up
            isKeyPressed = false
            lastKeyUpTime = eventTime

            if isToggleModeEnabled {
                // In toggle mode: don't stop on release
                return
            }

            // Hold-to-record mode: stop recording on release
            Log.app.info("\(self.selectedKey.displayName) released - stopping recording")
            onKeyUp?()
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
        case .rightCommand:
            return keyCode == 54 && flags.contains(.command)
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
        case .rightCommand:
            keyCode == 54
        }
    }
}
