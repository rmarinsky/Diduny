import AppKit
import ApplicationServices

/// Chat styling is a user-selected, language-independent casing rule.
/// It intentionally lowercases the first word, including names and acronyms.
enum MessageFormattingMode: String, CaseIterable, Identifiable {
    case normal
    case chat

    var id: String {
        rawValue
    }

    func format(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self == .chat, result.count <= 280,
              !result.contains(where: \.isNewline),
              result.split(whereSeparator: { $0.isWhitespace }).count <= 50 else { return result }

        let fullStops: Set<Character> = [".", "。", "．", "۔"]
        if let last = result.last, fullStops.contains(last),
           result.dropLast().last != last
        {
            result.removeLast()
        }

        // Skip opening quotes and punctuation; Unicode casing also supports non-Latin scripts.
        if let start = result.firstIndex(where: { $0.isLetter }) {
            let word = result[start...].prefix(while: { $0.isLetter || $0 == "’" || $0 == "'" })
            let end = result.index(start, offsetBy: word.count)
            result.replaceSubrange(start ..< end, with: word.lowercased())
        }
        return result
    }
}

enum ClipboardError: LocalizedError {
    case accessibilityNotGranted
    case pasteEventFailed
    case copyEventFailed
    case captureSelectionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            String(localized: "Accessibility permission required for auto-paste")
        case .pasteEventFailed:
            String(localized: "Failed to simulate paste keyboard event")
        case .copyEventFailed:
            String(localized: "Failed to simulate copy keyboard event")
        case .captureSelectionFailed:
            String(localized: "Failed to capture selected text")
        }
    }
}

final class ClipboardService {
    static let shared = ClipboardService()
    static let pasteReadinessDelayNanoseconds: UInt64 = 15_000_000
    static let shortcutKeyHoldMicroseconds: useconds_t = 12000

    private let pasteboard = NSPasteboard.general

    /// Set when ⌘V is posted; cleared when a paste starts, so a failed paste leaves nil.
    private(set) var lastPaste: Date?

    /// Called after every shortcut Diduny posts (paste, copy, submit). Set by `TypingEngineHost`.
    var onShortcutPosted: (@MainActor @Sendable () -> Void)?

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
        recordingType: Recording.RecordingType = .voice,
        mode: MessageFormattingMode = SettingsStorage.shared.messageFormattingMode
    ) -> String {
        switch recordingType {
        case .voice, .translation:
            mode.format(preparedText(text, behavior: .cleaned))
        case .meeting, .meetingTranslation, .fileTranscription:
            text
        }
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

    /// - Parameter expectedProcessIdentifier: when set, ⌘V is posted only if that app is still frontmost after the
    /// delay.
    func paste() async throws {
        try await paste(expectedProcessIdentifier: nil)
    }

    func paste(expectedProcessIdentifier: pid_t?) async throws {
        lastPaste = nil
        #if TEST_BUILD
            // `--ui-testing-stub-paste`: record instead of posting ⌘V.
            if UITestHarness.stubsPaste {
                UITestProbeCounters.recordPaste()
                lastPaste = Date()
                return
            }
        #endif
        // Check accessibility permission first
        let isGranted = ClipboardService.isAccessibilityGranted()
        Log.app.info("Accessibility permission check: \(isGranted)")

        guard isGranted else {
            Log.app.warning("Accessibility permission not granted")
            throw ClipboardError.accessibilityNotGranted
        }

        // Keep only a short focus handoff delay. NSPasteboard writes above are synchronous.
        try await Task.sleep(nanoseconds: Self.pasteReadinessDelayNanoseconds)

        if let expectedProcessIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedProcessIdentifier
        {
            throw ClipboardError.pasteEventFailed
        }

        try await postCommandShortcut(keyCode: CGKeyCode(9), error: .pasteEventFailed)
        lastPaste = Date()

        Log.app.info("Paste event sent successfully to frontmost app")
    }

    /// Captures selected text from the frontmost app by simulating Cmd+C.
    func captureSelectedText() async throws -> String {
        #if TEST_BUILD
            if let text = UITestHarness.stubbedSelection.withLock({ $0 }) { return text }
        #endif
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
               !selectedText.isEmpty
            {
                return selectedText
            }

            try await Task.sleep(nanoseconds: 40_000_000) // 0.04 seconds
        }

        throw ClipboardError.captureSelectionFailed
    }

    /// Papuga's `clipboardRestoreDelay`: how long the pasted text stays on the pasteboard before the old one returns.
    static let replaceSelectionRestoreDelay: Duration = .milliseconds(500)

    /// Copies the selection, pastes what `transform` makes of it, then puts the old pasteboard back.
    /// Returns nil when nothing was copied or `transform` returned nil; the pasteboard is restored either way.
    @MainActor
    func replaceSelection<Result>(
        _ transform: (String) -> (text: String, result: Result)?
    ) async throws -> Result? {
        guard ClipboardService.isAccessibilityGranted() else { throw ClipboardError.accessibilityNotGranted }
        let saved = Self.snapshot(pasteboard)
        let initialChangeCount = pasteboard.changeCount
        try await postCommandShortcut(keyCode: CGKeyCode(8), error: .copyEventFailed)

        var selection: String?
        for _ in 0 ..< 10 {
            if pasteboard.changeCount != initialChangeCount {
                selection = pasteboard.string(forType: .string)
                break
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        guard let selection, !selection.isEmpty, let output = transform(selection) else {
            Self.restore(saved, to: pasteboard)
            return nil
        }
        pasteboard.clearContents()
        pasteboard.setString(output.text, forType: .string)
        do {
            try await paste()
            try await Task.sleep(for: Self.replaceSelectionRestoreDelay)
        } catch {
            Self.restore(saved, to: pasteboard)
            throw error
        }
        Self.restore(saved, to: pasteboard)
        return output.result
    }

    /// Every item with every type, as data.
    static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }, uniquingKeysWith: { first, _ in first })
        }
    }

    static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }

    /// Sends the given shortcut to the frontmost app (used by Force submit after a successful paste).
    func sendShortcut(keyCode: CGKeyCode, flags: CGEventFlags) async throws {
        #if TEST_BUILD
            if UITestHarness.stubsPaste {
                UITestProbeCounters.recordSubmit()
                return
            }
        #endif
        guard ClipboardService.isAccessibilityGranted() else {
            throw ClipboardError.accessibilityNotGranted
        }
        // Let the target app finish handling the paste before submitting.
        try await Task.sleep(for: .milliseconds(80))
        try await postCommandShortcut(keyCode: keyCode, flags: flags, error: .pasteEventFailed)
    }

    /// Marks every key event Diduny posts ("DIDUNY" in ASCII), so a key event tap can tell them from real typing.
    static let syntheticEventMarker: Int64 = 0x4449_4455_4E59

    /// The key-down and key-up pair for a shortcut, both carrying `syntheticEventMarker`.
    static func makeShortcutEvents(keyCode: CGKeyCode, flags: CGEventFlags) -> (keyDown: CGEvent, keyUp: CGEvent)? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return nil }
        for event in [keyDown, keyUp] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        }
        return (keyDown, keyUp)
    }

    private func postCommandShortcut(
        keyCode: CGKeyCode,
        flags: CGEventFlags = .maskCommand,
        error: ClipboardError
    ) async throws {
        // The key-up is built up front and posted via defer so it always fires,
        // even if the hold-interval sleep below is cancelled (e.g. the user
        // re-triggers recording mid-paste). Otherwise the virtual ⌘ stays
        // "held" in the target app until the next real key event.
        guard let (keyDown, keyUp) = Self.makeShortcutEvents(keyCode: keyCode, flags: flags) else {
            Log.app.error("Failed to create shortcut events")
            throw error
        }

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        defer { keyUp.post(tap: .cgAnnotatedSessionEventTap) }
        // Not awaited: the key hold below must not wait for the main actor.
        if let onShortcutPosted { Task { @MainActor in onShortcutPosted() } }

        // Suspend rather than park the thread for the key-hold interval.
        try await Task.sleep(for: .milliseconds(12))
    }
}
