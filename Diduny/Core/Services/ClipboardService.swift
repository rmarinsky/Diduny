import AppKit
import ApplicationServices

/// Chat styling is deliberately conservative: unknown capitalized words retain their spelling.
/// Broaden the starter vocabulary only with language-specific regression examples.
enum MessageFormattingMode: String, CaseIterable, Identifiable {
    case normal
    case chat

    var id: String { rawValue }
    var displayName: String { self == .normal ? "Normal" : "For chat" }

    func format(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self == .chat, result.count <= 280,
              !result.contains(where: { $0.isNewline }),
              result.split(whereSeparator: { $0.isWhitespace }).count <= 50 else { return result }

        // Only sentence-ending periods are omitted. Keep ellipses and abbreviation endings.
        if result.hasSuffix("."), !result.hasSuffix(".."),
           let lastWord = result.split(whereSeparator: { $0.isWhitespace }).last,
           !lastWord.dropLast().contains("."),
           !(lastWord.dropLast().count == 1 && lastWord.first?.isUppercase == true),
           !["etc.", "dr.", "mr.", "mrs.", "ms.", "prof.", "р.", "ст.", "ім.", "вул."]
            .contains(lastWord.lowercased()) {
            result.removeLast()
        }

        let word = String(result.prefix(while: { $0.isLetter || $0 == "’" || $0 == "'" }))
        let starters: Set<String> = [
            "так", "ні", "ну", "добре", "гаразд", "дякую", "привіт", "зараз", "давай", "давайте",
            "буду", "перевір", "перевірю", "можеш", "можна", "будь", "будьмо", "це", "тут", "там", "я",
            "ми", "ти", "ви", "мені", "тобі", "нам", "вам", "ще", "вже", "тоді", "як", "чому",
            "yes", "no", "okay", "thanks", "thank", "hello", "hi", "please", "sure", "let", "can",
            "could", "would", "this", "that", "we", "you", "just", "now"
        ]
        if starters.contains(word.lowercased()), word != word.uppercased() || word == "Я" {
            result.replaceSubrange(result.startIndex..<result.index(result.startIndex, offsetBy: word.count),
                                   with: word.lowercased())
        }
        return result
    }
}

enum ClipboardCopyBehavior: Equatable {
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
    static let pasteReadinessDelayNanoseconds: UInt64 = 50_000_000
    static let shortcutKeyHoldMicroseconds: useconds_t = 12_000

    private let pasteboard = NSPasteboard.general

    static func preparedText(_ text: String, behavior: ClipboardCopyBehavior = .cleaned) -> String {
        switch behavior {
        case .cleaned:
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .raw:
            text
        }
    }

    /// Final message delivery only; generic clipboard and meeting transcripts keep their formatting.
    static func preparedMessageText(
        _ text: String,
        mode: MessageFormattingMode = SettingsStorage.shared.messageFormattingMode
    ) -> String {
        mode.format(preparedText(text, behavior: .cleaned))
    }

    func copy(text: String) {
        copy(text: text, behavior: .cleaned)
    }

    func copy(text: String, behavior: ClipboardCopyBehavior) {
        let normalizedText = Self.preparedText(text, behavior: behavior)

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

        // Keep only a short focus handoff delay. NSPasteboard writes above are synchronous.
        try await Task.sleep(nanoseconds: Self.pasteReadinessDelayNanoseconds)

        try await postCommandShortcut(keyCode: CGKeyCode(9), error: .pasteEventFailed)

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
        try await postCommandShortcut(keyCode: CGKeyCode(8), error: .copyEventFailed)

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

    private func postCommandShortcut(keyCode: CGKeyCode, error: ClipboardError) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.app.error("Failed to create event source")
            throw error
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            Log.app.error("Failed to create keyDown event")
            throw error
        }
        keyDown.flags = .maskCommand

        // Build the key-up up front and post it via defer so it always fires —
        // even if the hold-interval sleep below is cancelled (e.g. the user
        // re-triggers recording mid-paste). Otherwise the virtual ⌘ stays
        // "held" in the target app until the next real key event.
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.app.error("Failed to create keyUp event")
            throw error
        }
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        defer { keyUp.post(tap: .cgAnnotatedSessionEventTap) }

        // Suspend rather than park the thread for the key-hold interval.
        try await Task.sleep(for: .milliseconds(12))
    }
}
