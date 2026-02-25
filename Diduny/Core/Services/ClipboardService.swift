import AppKit
import ApplicationServices

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
    static let shared = ClipboardService()

    private let pasteboard = NSPasteboard.general

    func copy(text: String) {
        let normalizedText = ClipboardTextNormalizer.normalize(text)
        pasteboard.clearContents()
        pasteboard.setString(normalizedText, forType: .string)
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

private enum ClipboardTextNormalizer {
    static func normalize(_ text: String) -> String {
        var normalized = normalizeSpacing(in: text)

        guard SettingsStorage.shared.textCleanupEnabled else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        normalized = removeSingleLetterStutters(in: normalized)

        for fillerWord in SettingsStorage.shared.fillerWords {
            normalized = removeFillerWord(fillerWord, from: normalized)
        }

        normalized = normalizeSpacing(in: normalized)
        normalized = normalizePunctuation(in: normalized)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeSingleLetterStutters(in text: String) -> String {
        // Removes patterns like "е-е", "е-е-е", "m-m" when they are standalone tokens.
        replacing(
            in: text,
            pattern: "(?iu)(^|[^\\p{L}\\p{N}])([\\p{L}])(?:[-–—]\\2){1,}(?=$|[^\\p{L}\\p{N}])",
            with: "$1"
        )
    }

    private static func removeFillerWord(_ fillerWord: String, from text: String) -> String {
        let trimmed = fillerWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let pattern = "(?iu)(^|[^\\p{L}\\p{N}])\(escaped)(?:\\s*[,.;:!?])?(?=$|[^\\p{L}\\p{N}])"
        return replacing(in: text, pattern: pattern, with: "$1")
    }

    private static func normalizeSpacing(in text: String) -> String {
        var result = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        result = replacing(in: result, pattern: "[ \\t]+", with: " ")
        result = replacing(in: result, pattern: " *\\n *", with: "\n")
        result = replacing(in: result, pattern: "\\n{3,}", with: "\n\n")
        return result
    }

    private static func normalizePunctuation(in text: String) -> String {
        var result = text
        result = replacing(in: result, pattern: "\\s+([,.;:!?])", with: "$1")
        result = replacing(in: result, pattern: "([\\(\\[\\{])\\s+", with: "$1")
        result = replacing(in: result, pattern: "\\s+([\\)\\]\\}])", with: "$1")
        result = replacing(in: result, pattern: "([,.;:!?]){2,}", with: "$1")
        return result
    }

    private static func replacing(in text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: template)
    }
}
