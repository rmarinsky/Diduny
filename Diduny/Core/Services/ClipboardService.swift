import AppKit
import ApplicationServices

enum ClipboardCopyBehavior {
    case cleaned
    case raw
}

enum ClipboardError: LocalizedError {
    case accessibilityNotGranted
    case pasteEventFailed
    case copyEventFailed
    case captureSelectionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "Accessibility permission required for auto-paste"
        case .pasteEventFailed:
            "Failed to simulate paste keyboard event"
        case .copyEventFailed:
            "Failed to simulate copy keyboard event"
        case .captureSelectionFailed:
            "Failed to capture selected text"
        }
    }
}

final class ClipboardService: ClipboardServiceProtocol {
    static let shared = ClipboardService()

    private let pasteboard = NSPasteboard.general

    func copy(text: String) {
        copy(text: text, behavior: .cleaned)
    }

    func copy(text: String, behavior: ClipboardCopyBehavior) {
        let normalizedText: String
        switch behavior {
        case .cleaned:
            normalizedText = ClipboardTextNormalizer.normalize(text)
        case .raw:
            normalizedText = text
        }

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

        try postCommandShortcut(keyCode: CGKeyCode(9), error: .pasteEventFailed)

        Log.app.info("Paste event sent successfully to frontmost app")
    }

    /// Captures selected text from the frontmost app by simulating Cmd+C.
    func captureSelectedText() async throws -> String {
        let isGranted = ClipboardService.isAccessibilityGranted()
        Log.app.info("Accessibility permission check (copy): \(isGranted)")

        guard isGranted else {
            Log.app.warning("Accessibility permission not granted for copy")
            throw ClipboardError.accessibilityNotGranted
        }

        let initialChangeCount = pasteboard.changeCount
        try postCommandShortcut(keyCode: CGKeyCode(8), error: .copyEventFailed)

        let timeout = Date().addingTimeInterval(0.8)
        while Date() < timeout {
            if pasteboard.changeCount != initialChangeCount,
               let selectedText = pasteboard.string(forType: .string)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !selectedText.isEmpty {
                return selectedText
            }

            try await Task.sleep(nanoseconds: 40_000_000) // 0.04 seconds
        }

        throw ClipboardError.captureSelectionFailed
    }

    func getContent() -> String? {
        pasteboard.string(forType: .string)
    }

    private func postCommandShortcut(keyCode: CGKeyCode, error: ClipboardError) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.app.error("Failed to create event source")
            throw error
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            Log.app.error("Failed to create keyDown event")
            throw error
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)

        // Keep a tiny delay between key down/up so target apps can process shortcuts reliably.
        usleep(30_000)

        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.app.error("Failed to create keyUp event")
            throw error
        }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}

private enum ClipboardTextNormalizer {
    private static let regexCache = RegexCache()

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
        normalized = normalizeEnumerations(in: normalized)
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

    private static func normalizeEnumerations(in text: String) -> String {
        var result = text
        let ordinal = "по-(?:перше|друге|третє|четверте|п[‘’]?яте|шосте|сьоме|восьме|дев[‘’]?яте|десяте)"

        // Break lines before ordinal list markers.
        result = replacing(
            in: result,
            pattern: "(?iu)([:.!?])\\s*(\(ordinal)\\b)",
            with: "$1\n$2"
        )

        // If enumeration starts with "По-перше" after sentence punctuation, prefer ":" as list opener.
        result = replacing(
            in: result,
            pattern: "(?iu)[.!?]\\n(по-перше\\b)",
            with: ":\n$1"
        )

        // Keep list blocks compact.
        result = replacing(in: result, pattern: "\\n{3,}", with: "\n\n")
        return result
    }

    private static func replacing(in text: String, pattern: String, with template: String) -> String {
        guard let regex = regexCache.regex(for: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: template)
    }
}

private final class RegexCache: @unchecked Sendable {
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = regex
        return regex
    }
}
