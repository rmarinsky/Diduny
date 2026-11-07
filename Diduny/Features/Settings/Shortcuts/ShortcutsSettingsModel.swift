import Foundation
import KeyboardShortcuts
import Observation

/// Page view of WP-15's `ShortcutRow` (05 §2.5).
extension ShortcutRow: Identifiable {
    var id: String { rawValue }

    /// The row's name in test-plan 2.1 identifiers.
    var identifierName: String {
        switch self {
        case .cancelRecording: "escapeCancel"
        case .historyPalette: "toggleHistoryPalette"
        default: rawValue
        }
    }

    /// The package recorder's name for chord rows. Nil for the two rows that use
    /// `ShortcutCaptureField` (ADR-0012 D8): Cancel (any key) and in place (modifier-only or key chord).
    var shortcutName: KeyboardShortcuts.Name? {
        self == .inplaceTranslation ? nil : hotkeyName
    }

    var keysIdentifier: String { "shortcuts.\(identifierName).keys" }
    var pressCountIdentifier: String { "shortcuts.\(identifierName).pressCount" }
    var enabledIdentifier: String { "shortcuts.\(identifierName).enabled" }
}

/// What the Shortcuts page reads and writes. `SettingsShortcutsStore` backs it with WP-15's
/// shortcuts model; tests use a fake.
@MainActor
protocol ShortcutsSettingsStore: AnyObject {
    /// Display string ("⌥⌘B"); nil when no shortcut is set.
    func keys(for row: ShortcutRow) -> String?
    func pressCount(for row: ShortcutRow) -> Int
    func setPressCount(_ count: Int, for row: ShortcutRow)
    func isEnabled(_ row: ShortcutRow) -> Bool
    /// Off keeps the keys (05 §2.5).
    func setEnabled(_ isOn: Bool, for row: ShortcutRow)
    /// A new shortcut was recorded for the row; re-register as needed.
    func shortcutDidChange(_ row: ShortcutRow)
    /// Stores what `ShortcutCaptureField` captured for Cancel or in place (D8).
    func saveCaptured(_ value: ShortcutCaptureMachine.Captured, for row: ShortcutRow)
    /// Chords of the other Diduny shortcuts, so an in-place key chord does not take one.
    func takenShortcuts(excluding row: ShortcutRow) -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut]
    var keepsAudioWhenCancelled: Bool { get set }
    /// The in-place row holds a modifier-only chord (D8), so 1× is not allowed.
    var inplaceUsesModifierChord: Bool { get }
    /// Push-to-talk keys own both sides of the chord's modifiers (Inv 3.3).
    var inplaceBlockedByPushToTalk: Bool { get }
    /// Every pair of Your languages.
    var offeredPairs: [TranslationLanguagePair] { get }
    /// "Pair for both directions" (decision 2).
    var currentPair: TranslationLanguagePair? { get }
    func selectPair(_ pair: TranslationLanguagePair)
}

/// Page rules for Settings > Shortcuts, free of AppKit so they are unit-tested.
@MainActor
@Observable
final class ShortcutsSettingsModel {
    enum GroupID: String { case whileRecording, text, app }

    enum Item: Equatable, Identifiable {
        case shortcut(ShortcutRow)
        case keepAudioWhenCancelled
        case inplacePair
        case openSettings

        var id: String {
            switch self {
            case let .shortcut(row): row.identifierName
            case .keepAudioWhenCancelled: "escapeCancelSaveAudio"
            case .inplacePair: "inplaceTranslationPair"
            case .openSettings: "openSettings"
            }
        }
    }

    struct Group: Identifiable {
        let id: GroupID
        let items: [Item]
    }

    /// `PAGES.shortcuts` (prototype.html:750-753).
    static let groups: [Group] = [
        Group(id: .whileRecording, items: [
            .shortcut(.cancelRecording), .keepAudioWhenCancelled, .shortcut(.forceSubmit), .shortcut(.addMeetingChapter),
        ]),
        Group(id: .text, items: [.shortcut(.translateSelectedText), .shortcut(.inplaceTranslation), .inplacePair]),
        Group(id: .app, items: [.shortcut(.historyPalette), .openSettings]),
    ]

    static let pressCounts = 1 ... 3

    @ObservationIgnored let store: ShortcutsSettingsStore
    /// Bumped on every write so views re-read the store.
    private(set) var revision = 0

    init(store: ShortcutsSettingsStore) {
        self.store = store
    }

    func keys(for row: ShortcutRow) -> String? {
        _ = revision
        return store.keys(for: row)
    }

    func isEnabled(_ row: ShortcutRow) -> Bool {
        _ = revision
        return store.isEnabled(row)
    }

    func setEnabled(_ isOn: Bool, for row: ShortcutRow) {
        store.setEnabled(isOn, for: row)
        revision += 1
    }

    /// 1× is disabled for a modifier-only in-place chord (D8).
    func isPressCountSelectable(_ count: Int, for row: ShortcutRow) -> Bool {
        guard Self.pressCounts.contains(count) else { return false }
        return !(row == .inplaceTranslation && store.inplaceUsesModifierChord && count == 1)
    }

    /// A stored 1× on a modifier chord reads as 2 (the store is not rewritten).
    func displayedPressCount(for row: ShortcutRow) -> Int {
        _ = revision
        let stored = min(max(store.pressCount(for: row), 1), 3)
        return isPressCountSelectable(stored, for: row) ? stored : 2
    }

    func setPressCount(_ count: Int, for row: ShortcutRow) {
        guard isPressCountSelectable(count, for: row) else { return }
        store.setPressCount(count, for: row)
        revision += 1
    }

    func shortcutDidChange(_ row: ShortcutRow) {
        store.shortcutDidChange(row)
        revision += 1
    }

    func saveCaptured(_ value: ShortcutCaptureMachine.Captured, for row: ShortcutRow) {
        store.saveCaptured(value, for: row)
        revision += 1
    }

    var keepsAudioWhenCancelled: Bool {
        get { _ = revision; return store.keepsAudioWhenCancelled }
        set { store.keepsAudioWhenCancelled = newValue; revision += 1 }
    }

    var inplaceBlocked: Bool {
        _ = revision
        return store.inplaceBlockedByPushToTalk
    }

    var inplaceUsesModifierChord: Bool {
        _ = revision
        return store.inplaceUsesModifierChord
    }

    var pairOptions: [TranslationLanguagePair] {
        _ = revision
        return store.offeredPairs
    }

    var selectedPairID: String? {
        _ = revision
        return store.currentPair?.id
    }

    func selectPair(id: String) {
        guard let pair = store.offeredPairs.first(where: { $0.id == id }) else { return }
        store.selectPair(pair)
        revision += 1
    }
}
