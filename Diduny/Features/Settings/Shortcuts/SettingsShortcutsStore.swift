import Foundation
import KeyboardShortcuts

/// The Shortcuts page backed by WP-15's shortcuts model (`SettingsStorage+Shortcuts`, ADR-0012 D8).
@MainActor
final class SettingsShortcutsStore: ShortcutsSettingsStore {
    private let settings: SettingsStorage

    init(settings: SettingsStorage = .shared) {
        self.settings = settings
    }

    func keys(for row: ShortcutRow) -> String? {
        switch settings.shortcutSetting(for: row).keys {
        case let .cancelKey(shortcut):
            shortcut.displayName
        case let .inplace(.modifierChord(families)):
            families.displaySymbols
        case .inplace(.keyChord):
            KeyboardShortcuts.getShortcut(for: .inplaceTranslation).map { String(describing: $0) }
        case let .chord(name):
            KeyboardShortcuts.getShortcut(for: name).map { String(describing: $0) }
        }
    }

    func pressCount(for row: ShortcutRow) -> Int {
        settings.shortcutSetting(for: row).pressCount
    }

    func setPressCount(_ count: Int, for row: ShortcutRow) {
        settings.setShortcutPressCount(count, for: row)
    }

    func isEnabled(_ row: ShortcutRow) -> Bool {
        settings.shortcutSetting(for: row).enabled
    }

    func setEnabled(_ isOn: Bool, for row: ShortcutRow) {
        settings.setShortcutEnabled(isOn, for: row)
        guard !isOn else { return }
        switch row {
        case .cancelRecording: EscapeCancelService.shared.deactivate()
        case .forceSubmit: ForceSubmitService.shared.deactivate()
        default: break
        }
    }

    /// Recording a shortcut registers it system-wide at once; keep Force submit off while idle, as
    /// the old row did, and re-apply the switches so an off row stays off.
    func shortcutDidChange(_ row: ShortcutRow) {
        if row == .forceSubmit, !ForceSubmitService.shared.isActive {
            KeyboardShortcuts.disable(.forceSubmit)
        }
        NotificationCenter.default.post(name: .shortcutSwitchesChanged, object: nil)
    }

    func saveCaptured(_ value: ShortcutCaptureMachine.Captured, for row: ShortcutRow) {
        switch (row, value) {
        case let (.cancelRecording, .cancelKey(shortcut)):
            settings.escapeCancelShortcut = shortcut
        case let (.inplaceTranslation, .modifierChord(families)):
            settings.saveInplaceTranslationShortcut(modifiers: families)
        case let (.inplaceTranslation, .keyChord(chord)):
            settings.saveInplaceTranslationShortcut(keyChord: chord)
        default:
            return
        }
        shortcutDidChange(row)
    }

    func takenShortcuts(excluding row: ShortcutRow) -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] {
        var taken: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
        let names: [KeyboardShortcuts.Name] = [
            .toggleRecording, .toggleMeetingRecording, .toggleMeetingTranslation, .toggleTranslation,
            .addMeetingChapter, .toggleHistoryPalette, .forceSubmit, .translateSelectedText, .inplaceTranslation,
        ]
        for name in names where name != row.hotkeyName {
            if let shortcut = KeyboardShortcuts.getShortcut(for: name) { taken[name] = shortcut }
        }
        return taken
    }

    var keepsAudioWhenCancelled: Bool {
        get { settings.escapeCancelSaveAudio }
        set { settings.escapeCancelSaveAudio = newValue }
    }

    var inplaceUsesModifierChord: Bool {
        settings.inplaceTranslationShortcut.modifierFamilies != nil
    }

    var inplaceBlockedByPushToTalk: Bool {
        let reserved = PushToTalkKey.reservedForInplaceTranslation([
            (settings.pushToTalkKey, settings.pushToTalkHoldEnabled || settings.pushToTalkToggleEnabled),
            (
                settings.translationPushToTalkKey,
                settings.translationPushToTalkHoldEnabled || settings.translationPushToTalkToggleEnabled
            ),
        ])
        return PushToTalkKey.blocksInplaceTranslation(reserved)
    }

    var offeredPairs: [TranslationLanguagePair] { settings.offeredTranslationPairs }
    var currentPair: TranslationLanguagePair? { settings.translationPair }
    func selectPair(_ pair: TranslationLanguagePair) { settings.selectTranslationPair(pair) }
}
