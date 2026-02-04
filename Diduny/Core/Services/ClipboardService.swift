import AppKit
import ApplicationServices
import Carbon
import os

enum ClipboardError: LocalizedError {
    case accessibilityNotGranted
    case pasteEventFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "Accessibility permission required for auto-paste"
        case .pasteEventFailed:
            "Failed to simulate paste keyboard event"
        }
    }
}

final class ClipboardService: ClipboardServiceProtocol {
    private let pasteboard = NSPasteboard.general

    func copy(text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Check if accessibility permission is granted
    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Request accessibility permission (opens System Settings)
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func paste() async throws {
        // Check accessibility permission first
        let isGranted = ClipboardService.isAccessibilityGranted()
        Log.app.info("Accessibility permission check: \(isGranted)")

        guard isGranted else {
            Log.app.warning("Accessibility permission not granted")
            throw ClipboardError.accessibilityNotGranted
        }

        // Delay to ensure clipboard is ready and target app is focused
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

        // Simulate Cmd+V using CGEvent
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.app.error("Failed to create event source")
            throw ClipboardError.pasteEventFailed
        }

        // Key down: V (keycode 9) with Command modifier
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: true) else {
            Log.app.error("Failed to create keyDown event")
            throw ClipboardError.pasteEventFailed
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)

        // Small delay between key down and up
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds

        // Key up: V with Command
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: false) else {
            Log.app.error("Failed to create keyUp event")
            throw ClipboardError.pasteEventFailed
        }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        Log.app.info("Paste event sent successfully to frontmost app")
    }

    func getContent() -> String? {
        pasteboard.string(forType: .string)
    }
}
