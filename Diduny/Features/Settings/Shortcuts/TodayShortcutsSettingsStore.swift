import Foundation
import KeyboardShortcuts

/// Today's settings behind the Shortcuts page, until WP-15's shortcuts model lands.
///
/// Values WP-15 adds (press counts of force submit, chapter, history palette and in place; switches
/// of chapter, translate selected text and history palette) have no storage yet: they are held in
/// memory with ADR-0012 D8 defaults and do not reach the hotkey services. WP-15 replaces this type.
@MainActor
final class TodayShortcutsSettingsStore: ShortcutsSettingsStore {
    private let settings: SettingsStorage
    private var pendingCounts: [ShortcutRow: Int] = [
        .forceSubmit: 1, .addMeetingChapter: 1, .toggleHistoryPalette: 1, .inplaceTranslation: 2,
    ]
    private var pendingEnabled: [ShortcutRow: Bool] = [:]

    init(settings: SettingsStorage = .shared) {
        self.settings = settings
    }

    func keys(for row: ShortcutRow) -> String? {
        switch row {
        case .escapeCancel: settings.escapeCancelShortcut.displayName
        case .inplaceTranslation: "⌥⌘"
        default: row.shortcutName.flatMap(KeyboardShortcuts.getShortcut(for:)).map { String(describing: $0) }
        }
    }

    func pressCount(for row: ShortcutRow) -> Int {
        switch row {
        case .escapeCancel: settings.escapeCancelPressCount
        case .translateSelectedText: settings.translateSelectedTextHotkeyPressCount
        default: pendingCounts[row] ?? 1
        }
    }

    func setPressCount(_ count: Int, for row: ShortcutRow) {
        switch row {
        // Today's storage clamps Cancel to 2...3; WP-15 widens it to 1...3.
        case .escapeCancel: settings.escapeCancelPressCount = count
        case .translateSelectedText: settings.translateSelectedTextHotkeyPressCount = count
        default: pendingCounts[row] = count
        }
    }

    func isEnabled(_ row: ShortcutRow) -> Bool {
        switch row {
        case .escapeCancel: settings.escapeCancelEnabled
        case .forceSubmit: settings.forceSubmitEnabled
        case .inplaceTranslation: settings.inplaceTranslationEnabled
        default: pendingEnabled[row] ?? true
        }
    }

    func setEnabled(_ isOn: Bool, for row: ShortcutRow) {
        switch row {
        case .escapeCancel:
            settings.escapeCancelEnabled = isOn
            if !isOn { EscapeCancelService.shared.deactivate() }
        case .forceSubmit:
            settings.forceSubmitEnabled = isOn
            if !isOn { ForceSubmitService.shared.deactivate() }
        case .inplaceTranslation:
            settings.inplaceTranslationEnabled = isOn
        default:
            pendingEnabled[row] = isOn
        }
    }

    /// Recording a shortcut registers it system-wide at once; keep Force submit off while idle, as
    /// the old row did. Re-registering the other rows (chapter outside a meeting) is WP-15's.
    func shortcutDidChange(_ row: ShortcutRow) {
        if row == .forceSubmit, !ForceSubmitService.shared.isActive {
            KeyboardShortcuts.disable(.forceSubmit)
        }
    }

    var keepsAudioWhenCancelled: Bool {
        get { settings.escapeCancelSaveAudio }
        set { settings.escapeCancelSaveAudio = newValue }
    }

    var inplaceUsesModifierChord: Bool { true }

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
