@testable import Diduny
import Foundation
import KeyboardShortcuts
import Testing

/// WP-55: Settings > Shortcuts page rules (05 §2.5, design-spec 4.14, ADR-0012 D8), read through a
/// fake store so no test touches `SettingsStorage.shared` (test-plan 7.6).
@MainActor
struct ShortcutsSettingsModelTests {
    private let store = FakeShortcutsSettingsStore()
    private var model: ShortcutsSettingsModel { ShortcutsSettingsModel(store: store) }

    @Test("Page groups and rows in the prototype's order")
    func groupsAndRows() {
        #expect(ShortcutsSettingsModel.groups.map(\.id) == [.whileRecording, .text, .app])
        #expect(ShortcutsSettingsModel.groups.map(\.items) == [
            [.shortcut(.cancelRecording), .keepAudioWhenCancelled, .shortcut(.forceSubmit), .shortcut(.addMeetingChapter)],
            [.shortcut(.translateSelectedText), .shortcut(.inplaceTranslation), .inplacePair],
            [.shortcut(.historyPalette), .openSettings],
        ])
    }

    @Test("Only the two special rows use the in-repo capture field (D8)")
    func captureKinds() {
        #expect(ShortcutRow.cancelRecording.shortcutName == nil)
        #expect(ShortcutRow.inplaceTranslation.shortcutName == nil)
        #expect(ShortcutRow.forceSubmit.shortcutName == .forceSubmit)
        #expect(ShortcutRow.addMeetingChapter.shortcutName == .addMeetingChapter)
        #expect(ShortcutRow.translateSelectedText.shortcutName == .translateSelectedText)
        #expect(ShortcutRow.historyPalette.shortcutName == .toggleHistoryPalette)
    }

    @Test("Identifiers follow test-plan 2.1", arguments: ShortcutRow.allCases)
    func identifiers(row: ShortcutRow) {
        #expect(row.keysIdentifier == "shortcuts.\(row.identifierName).keys")
        #expect(row.pressCountIdentifier == "shortcuts.\(row.identifierName).pressCount")
        #expect(row.enabledIdentifier == "shortcuts.\(row.identifierName).enabled")
    }

    @Test("A switch off disables keys and count and keeps the keys", arguments: ShortcutRow.allCases)
    func switchOffKeepsKeys(row: ShortcutRow) {
        let model = model
        let keys = model.keys(for: row)
        model.setEnabled(false, for: row)
        #expect(model.isEnabled(row) == false)
        #expect(model.keys(for: row) == keys)
        #expect(store.enabled[row] == false)
        model.setEnabled(true, for: row)
        #expect(model.isEnabled(row))
    }

    @Test("Every row offers 1× 2× 3× and stores the pick", arguments: ShortcutRow.allCases)
    func pressCountStored(row: ShortcutRow) {
        store.inplaceUsesModifierChord = false
        let model = model
        for count in 1 ... 3 {
            #expect(model.isPressCountSelectable(count, for: row))
            model.setPressCount(count, for: row)
            #expect(store.counts[row] == count)
            #expect(model.displayedPressCount(for: row) == count)
        }
    }

    @Test("In-place with a modifier chord: 1× is disabled and reads as 2 (D8)")
    func inplaceModifierChordNoSingle() {
        store.inplaceUsesModifierChord = true
        store.counts[.inplaceTranslation] = 1
        let model = model
        #expect(model.isPressCountSelectable(1, for: .inplaceTranslation) == false)
        #expect(model.displayedPressCount(for: .inplaceTranslation) == 2)
        model.setPressCount(1, for: .inplaceTranslation)
        #expect(store.counts[.inplaceTranslation] == 1, "a refused pick does not write")
        model.setPressCount(3, for: .inplaceTranslation)
        #expect(store.counts[.inplaceTranslation] == 3)
    }

    @Test("In-place with a key chord allows 1×")
    func inplaceKeyChordAllowsSingle() {
        store.inplaceUsesModifierChord = false
        #expect(model.isPressCountSelectable(1, for: .inplaceTranslation))
    }

    @Test("Out-of-range counts are not written")
    func outOfRange() {
        let model = model
        model.setPressCount(0, for: .forceSubmit)
        model.setPressCount(4, for: .forceSubmit)
        #expect(store.counts[.forceSubmit] == 1)
    }

    @Test("Keep the audio when cancelled writes through")
    func keepAudio() {
        let model = model
        model.keepsAudioWhenCancelled = false
        #expect(store.keepsAudioWhenCancelled == false)
    }

    @Test("Pair menu lists the offered pairs in full names and stores the pick")
    func pairMenu() {
        let enPl = TranslationLanguagePair(languageA: "en", languageB: "pl")
        store.offeredPairs = [TranslationLanguagePair(languageA: "en", languageB: "uk"), enPl]
        let model = model
        #expect(model.pairOptions.map(\.id) == ["en-uk", "en-pl"])
        #expect(model.selectedPairID == "en-uk")
        model.selectPair(id: "en-pl")
        #expect(store.selectedPair == enPl)
        #expect(model.selectedPairID == "en-pl")
        model.selectPair(id: "xx-yy")
        #expect(store.selectedPair == enPl, "an unknown id is ignored")
    }

    @Test("Blocked by push-to-talk keys shows the reason; the switch keeps its value")
    func blocked() {
        store.inplaceBlockedByPushToTalk = true
        let model = model
        #expect(model.inplaceBlocked)
        #expect(model.isEnabled(.inplaceTranslation))
    }

    @Test("A recorded chord is reported once to the store")
    func shortcutChanged() {
        model.shortcutDidChange(.addMeetingChapter)
        #expect(store.changed == [.addMeetingChapter])
    }

    @Test("Writes bump the revision so the page re-reads the store")
    func revision() {
        let model = model
        let start = model.revision
        model.setEnabled(false, for: .forceSubmit)
        model.setPressCount(2, for: .forceSubmit)
        model.shortcutDidChange(.forceSubmit)
        #expect(model.revision == start + 3)
    }
}

@MainActor
final class FakeShortcutsSettingsStore: ShortcutsSettingsStore {
    var keysByRow: [ShortcutRow: String] = [
        .cancelRecording: "Esc", .forceSubmit: "⌘↩", .addMeetingChapter: "⌥⌘B",
        .translateSelectedText: "⌥⌘T", .inplaceTranslation: "⌥⌘", .historyPalette: "⌥⌘H",
    ]
    var counts: [ShortcutRow: Int] = [
        .cancelRecording: 2, .forceSubmit: 1, .addMeetingChapter: 1,
        .translateSelectedText: 1, .inplaceTranslation: 2, .historyPalette: 1,
    ]
    var enabled: [ShortcutRow: Bool] = Dictionary(uniqueKeysWithValues: ShortcutRow.allCases.map { ($0, true) })
    var changed: [ShortcutRow] = []
    var keepsAudioWhenCancelled = true
    var inplaceUsesModifierChord = true
    var inplaceBlockedByPushToTalk = false
    var offeredPairs = [TranslationLanguagePair(languageA: "en", languageB: "uk")]
    var selectedPair: TranslationLanguagePair?

    func keys(for row: ShortcutRow) -> String? { keysByRow[row] }
    func pressCount(for row: ShortcutRow) -> Int { counts[row] ?? 1 }
    func setPressCount(_ count: Int, for row: ShortcutRow) { counts[row] = count }
    func isEnabled(_ row: ShortcutRow) -> Bool { enabled[row] ?? true }
    func setEnabled(_ isOn: Bool, for row: ShortcutRow) { enabled[row] = isOn }
    func shortcutDidChange(_ row: ShortcutRow) { changed.append(row) }
    var captured: [(ShortcutRow, ShortcutCaptureMachine.Captured)] = []
    func saveCaptured(_ value: ShortcutCaptureMachine.Captured, for row: ShortcutRow) { captured.append((row, value)) }
    func takenShortcuts(excluding _: ShortcutRow) -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] { [:] }
    func selectPair(_ pair: TranslationLanguagePair) { selectedPair = pair }
    var currentPair: TranslationLanguagePair? { selectedPair ?? offeredPairs.first }
}
