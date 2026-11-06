import AppKit
import KeyboardShortcuts

/// Capture rules for the two rows `KeyboardShortcuts.RecorderCocoa` cannot record (ADR-0012 D8).
/// Pure: fed with `KeyEvent` values by `ShortcutCaptureField`, so it is tested without AppKit.
struct ShortcutCaptureMachine {
    enum Mode: Equatable {
        /// Cancel recording: Esc or F1-F20 bare, any other key with ⌘ ⌥ ⌃. Esc is a value here.
        case singleKey
        /// Translate in place: a modifier chord of 2+ families, or a key chord.
        case chordOrModifiers
    }

    enum Captured: Equatable {
        case cancelKey(RecordingCancelShortcut)
        case modifierChord(ModifierFamilies)
        case keyChord(KeyboardShortcuts.Shortcut)
    }

    enum Rejection: Equatable {
        /// A bare key, or one with only ⇧. The field beeps; capture continues.
        case needsModifier
        /// Another Diduny shortcut uses this chord.
        case alreadyUsed(KeyboardShortcuts.Name)
    }

    enum Output: Equatable {
        case pending
        case commit(Captured)
        /// Keep the old value.
        case abort
        case reject(Rejection)
    }

    private static let tabKeyCode: UInt16 = 48
    private static let deleteKeyCode: UInt16 = 51

    let mode: Mode
    /// Chords of the other Diduny shortcuts; an in-place key chord equal to one is refused.
    let takenShortcuts: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut]
    private(set) var isFinished = false
    private var peakFamilies: ModifierFamilies = []
    private var sawKeyDown = false

    init(mode: Mode, takenShortcuts: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]) {
        self.mode = mode
        self.takenShortcuts = takenShortcuts
    }

    /// Click outside the field, Tab away, or loss of key window.
    mutating func abort() -> Output {
        guard !isFinished else { return .pending }
        return finish(.abort)
    }

    mutating func handle(_ event: KeyEvent) -> Output {
        guard !isFinished else { return .pending }
        switch event {
        case let .flagsChanged(_, flagsRawValue, _):
            guard mode == .chordOrModifiers else { return .pending }
            return handleFlags(ModifierFamilies(flags: NSEvent.ModifierFlags(rawValue: flagsRawValue)))
        case let .keyDown(keyCode, modifiersRawValue, isRepeat, _, characters):
            guard !isRepeat else { return .pending }
            sawKeyDown = true
            let flags = NSEvent.ModifierFlags(rawValue: modifiersRawValue)
            return mode == .singleKey
                ? handleSingleKey(keyCode, flags: flags, characters: characters)
                : handleChordKey(keyCode, flags: flags)
        }
    }

    // MARK: - Cancel row

    private mutating func handleSingleKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Output {
        let families = ModifierFamilies(flags: flags)
        if keyCode == Self.tabKeyCode, !families.hasNonShiftModifier {
            return finish(.abort)
        }
        if keyCode == Self.deleteKeyCode, families.isEmpty {
            return finish(.commit(.cancelKey(.defaultShortcut)))
        }
        guard Self.isAccepted(keyCode, families) else { return .reject(.needsModifier) }
        let shortcut = RecordingCancelShortcut.make(
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: families.rawValue),
            characters: characters
        )
        return finish(.commit(.cancelKey(shortcut)))
    }

    // MARK: - In-place row

    private mutating func handleFlags(_ families: ModifierFamilies) -> Output {
        guard families.isEmpty else {
            peakFamilies.formUnion(families)
            return .pending
        }
        // Full release: a chord of 2+ families with no key in between is the value.
        defer {
            peakFamilies = []
            sawKeyDown = false
        }
        guard !sawKeyDown, peakFamilies.count >= 2 else { return .pending }
        return finish(.commit(.modifierChord(peakFamilies)))
    }

    private mutating func handleChordKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Output {
        let families = ModifierFamilies(flags: flags)
        if keyCode == RecordingCancelShortcut.escapeKeyCode, families.isEmpty {
            return finish(.abort)
        }
        guard keyCode != RecordingCancelShortcut.escapeKeyCode, Self.isAccepted(keyCode, families) else {
            return .reject(.needsModifier)
        }
        let shortcut = KeyboardShortcuts.Shortcut(
            KeyboardShortcuts.Key(rawValue: Int(keyCode)),
            modifiers: NSEvent.ModifierFlags(rawValue: families.rawValue)
        )
        if let taken = takenShortcuts.first(where: { $0.value == shortcut })?.key {
            return .reject(.alreadyUsed(taken))
        }
        return finish(.commit(.keyChord(shortcut)))
    }

    // MARK: - Helpers

    /// Esc and F1-F20 bare, or any key with ⌘ ⌥ ⌃ (⇧ alone does not count).
    private static func isAccepted(_ keyCode: UInt16, _ families: ModifierFamilies) -> Bool {
        if families.hasNonShiftModifier { return true }
        let bareAllowed = keyCode == RecordingCancelShortcut.escapeKeyCode
            || RecordingCancelShortcut.functionKeyCodes.contains(keyCode)
        return bareAllowed && families.isEmpty
    }

    private mutating func finish(_ output: Output) -> Output {
        isFinished = true
        return output
    }
}

/// While a special row captures, Diduny's own hotkeys are off: a Carbon hotkey takes its keystroke
/// before any local monitor, so ⌥⌘T would run Translate selected text instead of being recorded.
///
/// `begin()` disables every registered name. `end()` does not replay that list: it posts
/// `didEndNotification`, and each owner (`HotkeyService`, `ForceSubmitService`,
/// `InplaceTranslationHotkeyMonitor`) re-asserts its own current state. So a name its owner
/// unregistered during capture (recording stopped) stays off, and a name registered during capture
/// goes live only at the end. Owners never enable a name while `isActive`; `PushToTalkService`,
/// `InplaceTranslationHotkeyMonitor` and `EscapeCancelService` ignore key events meanwhile.
final class ShortcutCaptureSession {
    static let shared = ShortcutCaptureSession()
    static let didEndNotification = Notification.Name("shortcutCaptureSessionDidEnd")

    /// Every `KeyboardShortcuts.Name` Diduny registers.
    static let managedNames: [KeyboardShortcuts.Name] = [
        .toggleRecording, .toggleTranslation, .toggleMeetingRecording, .toggleMeetingTranslation,
        .addMeetingChapter, .toggleHistoryPalette, .forceSubmit, .translateSelectedText, .inplaceTranslation
    ]

    private let registrar: HotkeyRegistrar
    let notifications: NotificationCenter
    private(set) var isActive = false

    init(
        registrar: HotkeyRegistrar = KeyboardShortcutsRegistrar.shared,
        notifications: NotificationCenter = .default
    ) {
        self.registrar = registrar
        self.notifications = notifications
    }

    func begin() {
        guard !isActive else { return }
        isActive = true
        Self.managedNames.filter { registrar.isEnabled($0) }.forEach { registrar.disable($0) }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        notifications.post(name: Self.didEndNotification, object: self)
    }

    /// Calls `handler` on the main thread after every `end()` of this session.
    func observeEnd(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        notifications.addObserver(forName: Self.didEndNotification, object: self, queue: nil) { _ in handler() }
    }
}
