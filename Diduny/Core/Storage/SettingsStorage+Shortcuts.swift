import Foundation
import KeyboardShortcuts

/// Shortcuts model storage (plan 3.5, ADR-0012 D4 and D8). Unset keys read as today's behaviour.
/// Existing keys (`escapeCancelShortcut`, `escapeCancelPressCount`, `escapeCancelEnabled`,
/// `forceSubmitEnabled`, `inplaceTranslationEnabled`, `translateSelectedTextHotkeyPressCount`) stay in
/// `SettingsStorage.swift`; this file adds the new ones and the per-row view.
extension SettingsStorage {
    private enum ShortcutsKey: String {
        case inplaceTranslationShortcut
        case inplaceTranslationPressCount
        case forceSubmitPressCount
        case addMeetingChapterPressCount
        case historyPalettePressCount
        case addMeetingChapterHotkeyEnabled
        case translateSelectedTextHotkeyEnabled
        case historyPaletteHotkeyEnabled
    }

    // MARK: - Translate in place

    /// Unset reads ⌥⌘, today's gesture.
    var inplaceTranslationShortcut: InplaceTranslationShortcut {
        get {
            guard let data = defaults.data(forKey: ShortcutsKey.inplaceTranslationShortcut.rawValue),
                  let value = try? JSONDecoder().decode(InplaceTranslationShortcut.self, from: data)
            else { return .default }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: ShortcutsKey.inplaceTranslationShortcut.rawValue)
            NotificationCenter.default.post(name: .inplaceTranslationSettingsChanged, object: nil)
        }
    }

    /// 1...3, unset 2. Read as at least 2 while a modifier chord is set; the stored value is not
    /// rewritten when the kind changes.
    var inplaceTranslationPressCount: Int {
        get {
            let stored = Self.storedPressCount(defaults, ShortcutsKey.inplaceTranslationPressCount, fallback: 2)
            return inplaceTranslationShortcut.modifierFamilies == nil ? stored : max(stored, 2)
        }
        set {
            setPressCount(newValue, ShortcutsKey.inplaceTranslationPressCount)
            NotificationCenter.default.post(name: .inplaceTranslationSettingsChanged, object: nil)
        }
    }

    /// Stores a modifier chord and removes the package chord, so no Carbon hotkey stays registered.
    func saveInplaceTranslationShortcut(
        modifiers: ModifierFamilies,
        registrar: HotkeyRegistrar = KeyboardShortcutsRegistrar.shared
    ) {
        registrar.setShortcut(nil, for: .inplaceTranslation)
        inplaceTranslationShortcut = .modifierChord(modifiers)
    }

    /// Stores a key chord in package storage and marks the key chord as the active kind.
    func saveInplaceTranslationShortcut(
        keyChord: KeyboardShortcuts.Shortcut,
        registrar: HotkeyRegistrar = KeyboardShortcutsRegistrar.shared
    ) {
        registrar.setShortcut(keyChord, for: .inplaceTranslation)
        inplaceTranslationShortcut = .keyChord
    }

    // MARK: - Press counts (1...3, unset 1)

    var forceSubmitPressCount: Int {
        get { Self.storedPressCount(defaults, ShortcutsKey.forceSubmitPressCount, fallback: 1) }
        set { setPressCount(newValue, ShortcutsKey.forceSubmitPressCount) }
    }

    var addMeetingChapterPressCount: Int {
        get { Self.storedPressCount(defaults, ShortcutsKey.addMeetingChapterPressCount, fallback: 1) }
        set { setPressCount(newValue, ShortcutsKey.addMeetingChapterPressCount) }
    }

    var historyPalettePressCount: Int {
        get { Self.storedPressCount(defaults, ShortcutsKey.historyPalettePressCount, fallback: 1) }
        set { setPressCount(newValue, ShortcutsKey.historyPalettePressCount) }
    }

    // MARK: - Switches (unset on)

    var addMeetingChapterHotkeyEnabled: Bool {
        get { switchValue(ShortcutsKey.addMeetingChapterHotkeyEnabled) }
        set { setSwitch(newValue, ShortcutsKey.addMeetingChapterHotkeyEnabled) }
    }

    var translateSelectedTextHotkeyEnabled: Bool {
        get { switchValue(ShortcutsKey.translateSelectedTextHotkeyEnabled) }
        set { setSwitch(newValue, ShortcutsKey.translateSelectedTextHotkeyEnabled) }
    }

    var historyPaletteHotkeyEnabled: Bool {
        get { switchValue(ShortcutsKey.historyPaletteHotkeyEnabled) }
        set { setSwitch(newValue, ShortcutsKey.historyPaletteHotkeyEnabled) }
    }

    // MARK: - Rows

    func shortcutSetting(for row: ShortcutRow) -> ShortcutSetting {
        switch row {
        case .cancelRecording:
            ShortcutSetting(keys: .cancelKey(escapeCancelShortcut), pressCount: escapeCancelPressCount, enabled: escapeCancelEnabled)
        case .forceSubmit:
            ShortcutSetting(keys: .chord(.forceSubmit), pressCount: forceSubmitPressCount, enabled: forceSubmitEnabled)
        case .addMeetingChapter:
            ShortcutSetting(
                keys: .chord(.addMeetingChapter),
                pressCount: addMeetingChapterPressCount,
                enabled: addMeetingChapterHotkeyEnabled
            )
        case .translateSelectedText:
            ShortcutSetting(
                keys: .chord(.translateSelectedText),
                pressCount: translateSelectedTextHotkeyPressCount,
                enabled: translateSelectedTextHotkeyEnabled
            )
        case .inplaceTranslation:
            ShortcutSetting(
                keys: .inplace(inplaceTranslationShortcut),
                pressCount: inplaceTranslationPressCount,
                enabled: inplaceTranslationEnabled
            )
        case .historyPalette:
            ShortcutSetting(
                keys: .chord(.toggleHistoryPalette),
                pressCount: historyPalettePressCount,
                enabled: historyPaletteHotkeyEnabled
            )
        }
    }

    func setShortcutPressCount(_ count: Int, for row: ShortcutRow) {
        switch row {
        case .cancelRecording: escapeCancelPressCount = count
        case .forceSubmit: forceSubmitPressCount = count
        case .addMeetingChapter: addMeetingChapterPressCount = count
        case .translateSelectedText: translateSelectedTextHotkeyPressCount = count
        case .inplaceTranslation: inplaceTranslationPressCount = count
        case .historyPalette: historyPalettePressCount = count
        }
    }

    /// Off keeps the keys and the count; the services disable the name (`HotkeyService.refreshSwitches`).
    func setShortcutEnabled(_ enabled: Bool, for row: ShortcutRow) {
        switch row {
        case .cancelRecording: escapeCancelEnabled = enabled
        case .forceSubmit: forceSubmitEnabled = enabled
        case .addMeetingChapter: addMeetingChapterHotkeyEnabled = enabled
        case .translateSelectedText: translateSelectedTextHotkeyEnabled = enabled
        case .inplaceTranslation: inplaceTranslationEnabled = enabled
        case .historyPalette: historyPaletteHotkeyEnabled = enabled
        }
    }

    // MARK: - Helpers

    /// Values outside 1...3 (and a missing value) read as `fallback`.
    static func validPressCount(_ value: Int?, fallback: Int) -> Int {
        guard let value, (1 ... 3).contains(value) else { return fallback }
        return value
    }

    private static func storedPressCount(_ defaults: UserDefaults, _ key: ShortcutsKey, fallback: Int) -> Int {
        validPressCount(defaults.object(forKey: key.rawValue) as? Int, fallback: fallback)
    }

    private func setPressCount(_ value: Int, _ key: ShortcutsKey) {
        defaults.set(min(max(value, 1), 3), forKey: key.rawValue)
    }

    private func switchValue(_ key: ShortcutsKey) -> Bool {
        defaults.object(forKey: key.rawValue) == nil || defaults.bool(forKey: key.rawValue)
    }

    private func setSwitch(_ value: Bool, _ key: ShortcutsKey) {
        defaults.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: .shortcutSwitchesChanged, object: nil)
    }
}

extension Notification.Name {
    /// A Shortcuts row switch changed; `HotkeyService.refreshSwitches()` re-applies them.
    static let shortcutSwitchesChanged = Notification.Name("shortcutSwitchesChanged")
}
