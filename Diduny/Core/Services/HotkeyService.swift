import Foundation
import KeyboardShortcuts

// MARK: - Shortcut Names Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.d, modifiers: [.command, .option]))
    static let toggleMeetingRecording = Self("toggleMeetingRecording", default: .init(.m, modifiers: [.command, .option]))
    static let toggleMeetingTranslation = Self(
        "toggleMeetingTranslation",
        default: .init(.m, modifiers: [.command, .option, .shift])
    )
    static let toggleTranslation = Self("toggleTranslation", default: .init(.slash, modifiers: [.command, .option]))
    static let addMeetingChapter = Self("addMeetingChapter", default: .init(.b, modifiers: [.command, .option]))
    static let toggleHistoryPalette = Self("toggleHistoryPalette", default: .init(.h, modifiers: [.command, .option]))
    static let forceSubmit = Self("forceSubmit", default: .init(.return, modifiers: [.command]))
    static let translateSelectedText = Self("translateSelectedText", default: .init(.t, modifiers: [.command, .option]))
    /// Translate in place as a key chord (ADR-0012 D8). No default: unset until the user records one.
    static let inplaceTranslation = Self("inplaceTranslation")
}

// MARK: - Hotkey Service

/// Carbon hotkeys through `HotkeyRegistrar`, with one `PressCounter` per name (plan 3.5).
/// Counts and switches are read at press time; a switch change calls `refreshSwitches()`.
final class HotkeyService: HotkeyServiceProtocol {
    /// Posted by `KeyboardShortcuts` 2.4.0 when a name's keys change (internal name in the package).
    static let packageShortcutDidChange = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    private struct Binding {
        let handler: () -> Void
        let pressCount: () -> Int
        let isOn: () -> Bool
        var counter = PressCounter()
    }

    /// Names this service registers; their keys may change while some are switched off or idle.
    private static let ownedNames: Set<KeyboardShortcuts.Name> = [
        .toggleRecording, .toggleTranslation, .toggleMeetingRecording, .toggleMeetingTranslation,
        .addMeetingChapter, .toggleHistoryPalette, .translateSelectedText
    ]

    private let settings: SettingsStorage
    private let registrar: HotkeyRegistrar
    private let clock: MonotonicClock
    private var bindings: [KeyboardShortcuts.Name: Binding] = [:]
    private let shortcutChanges: NotificationCenter?
    private var shortcutChangeObserver: NSObjectProtocol?

    init(
        settings: SettingsStorage = .shared,
        registrar: HotkeyRegistrar = KeyboardShortcutsRegistrar.shared,
        clock: MonotonicClock = SystemClock(),
        shortcutChanges: NotificationCenter? = .default
    ) {
        self.settings = settings
        self.registrar = registrar
        self.clock = clock
        self.shortcutChanges = shortcutChanges
        // Recording new keys registers them at once, also for a name that is off: turn it off again.
        shortcutChangeObserver = shortcutChanges?.addObserver(
            forName: Self.packageShortcutDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name else { return }
            self?.reapply(name)
        }
    }

    deinit {
        if let shortcutChangeObserver {
            shortcutChanges?.removeObserver(shortcutChangeObserver)
        }
    }

    // MARK: - Mode hotkeys

    func registerRecordingHotkey(handler: @escaping () -> Void) {
        register(.toggleRecording, pressCount: { [settings] in settings.recordingHotkeyPressCount }, handler: handler)
    }

    func unregisterRecordingHotkey() {
        unregister(.toggleRecording)
    }

    func registerMeetingHotkey(handler: @escaping () -> Void) {
        register(.toggleMeetingRecording, pressCount: { [settings] in settings.meetingHotkeyPressCount }, handler: handler)
    }

    func unregisterMeetingHotkey() {
        unregister(.toggleMeetingRecording)
    }

    func registerMeetingTranslationHotkey(handler: @escaping () -> Void) {
        register(
            .toggleMeetingTranslation,
            pressCount: { [settings] in settings.meetingTranslationHotkeyPressCount },
            handler: handler
        )
    }

    func unregisterMeetingTranslationHotkey() {
        unregister(.toggleMeetingTranslation)
    }

    func registerTranslationHotkey(handler: @escaping () -> Void) {
        register(.toggleTranslation, pressCount: { [settings] in settings.translationHotkeyPressCount }, handler: handler)
    }

    func unregisterTranslationHotkey() {
        unregister(.toggleTranslation)
    }

    // MARK: - Shortcuts rows with a switch

    /// Registered while a meeting records.
    func registerChapterHotkey(handler: @escaping () -> Void) {
        register(
            .addMeetingChapter,
            pressCount: { [settings] in settings.addMeetingChapterPressCount },
            isOn: { [settings] in settings.addMeetingChapterHotkeyEnabled },
            handler: handler
        )
    }

    func unregisterChapterHotkey() {
        unregister(.addMeetingChapter)
    }

    func registerHistoryPaletteHotkey(handler: @escaping () -> Void) {
        register(
            .toggleHistoryPalette,
            pressCount: { [settings] in settings.historyPalettePressCount },
            isOn: { [settings] in settings.historyPaletteHotkeyEnabled },
            handler: handler
        )
    }

    func unregisterHistoryPaletteHotkey() {
        unregister(.toggleHistoryPalette)
    }

    func registerTranslateSelectedTextHotkey(handler: @escaping () -> Void) {
        register(
            .translateSelectedText,
            pressCount: { [settings] in settings.translateSelectedTextHotkeyPressCount },
            isOn: { [settings] in settings.translateSelectedTextHotkeyEnabled },
            handler: handler
        )
    }

    func unregisterTranslateSelectedTextHotkey() {
        unregister(.translateSelectedText)
    }

    /// Re-applies every switch: off disables the name and keeps its keys; on enables it again.
    func refreshSwitches() {
        bindings.keys.forEach(reapply)
    }

    // MARK: - Convenience Methods

    func unregisterAll() {
        unregisterRecordingHotkey()
        unregisterMeetingHotkey()
        unregisterMeetingTranslationHotkey()
        unregisterTranslationHotkey()
        unregisterChapterHotkey()
        unregisterHistoryPaletteHotkey()
        unregisterTranslateSelectedTextHotkey()
    }

    // MARK: - Registration

    /// One handler per name: registering again replaces it instead of adding a second one.
    func register(
        _ name: KeyboardShortcuts.Name,
        pressCount: @escaping () -> Int,
        isOn: @escaping () -> Bool = { true },
        handler: @escaping () -> Void
    ) {
        bindings[name] = Binding(handler: handler, pressCount: pressCount, isOn: isOn)
        registrar.removeHandler(for: name)
        registrar.onKeyDown(for: name) { [weak self] in
            self?.handlePress(name)
        }
        reapply(name)
    }

    func unregister(_ name: KeyboardShortcuts.Name) {
        registrar.disable(name)
        registrar.removeHandler(for: name)
        bindings[name] = nil
    }

    private func reapply(_ name: KeyboardShortcuts.Name) {
        guard let binding = bindings[name] else {
            if Self.ownedNames.contains(name) { registrar.disable(name) }
            return
        }
        bindings[name]?.counter.reset()
        if binding.isOn() {
            registrar.enable(name)
        } else {
            registrar.disable(name)
        }
    }

    private func handlePress(_ name: KeyboardShortcuts.Name) {
        guard let binding = bindings[name], binding.isOn() else { return }
        let didTrigger = bindings[name]?.counter.register(at: clock.now, required: binding.pressCount()) ?? false
        if didTrigger {
            binding.handler()
        }
    }
}
