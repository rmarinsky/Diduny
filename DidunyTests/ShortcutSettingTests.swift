import AppKit
@testable import Diduny
import Foundation
import KeyboardShortcuts
import Testing

/// Shortcuts model (plan 3.5, ADR-0012 D4/D8): unset keys read as today; off keeps the keys.
final class ShortcutSettingTests {
    private let box = IsolatedSettings("ShortcutSettingTests")
    private var settings: SettingsStorage { box.settings }
    private var defaults: UserDefaults { box.defaults }

    private static let optionCommand: ModifierFamilies = [.option, .command]

    // MARK: - Defaults for existing users (05 4.3 step 9)

    @Test("T5-MIG-29 new switches default on and new counts default 1")
    func newKeysDefault() {
        #expect(settings.forceSubmitPressCount == 1)
        #expect(settings.addMeetingChapterPressCount == 1)
        #expect(settings.historyPalettePressCount == 1)
        #expect(settings.addMeetingChapterHotkeyEnabled)
        #expect(settings.translateSelectedTextHotkeyEnabled)
        #expect(settings.historyPaletteHotkeyEnabled)
    }

    @Test("T5-MIG-28 in-place defaults: ⌥⌘, 2x; a stored off stays off")
    func inplaceDefaults() {
        #expect(settings.inplaceTranslationShortcut == .modifierChord(Self.optionCommand))
        #expect(settings.inplaceTranslationPressCount == 2)

        defaults.set(false, forKey: "inplaceTranslationEnabled")
        #expect(!settings.inplaceTranslationEnabled)
        #expect(settings.shortcutSetting(for: .inplaceTranslation).enabled == false)
    }

    @Test("T5-MIG-27 cancel defaults read Esc, 2x, on, with no write; stored values are kept")
    func cancelDefaults() {
        #expect(settings.escapeCancelShortcut == .defaultShortcut)
        #expect(settings.escapeCancelPressCount == 2)
        #expect(settings.escapeCancelEnabled)
        #expect(defaults.object(forKey: "escapeCancelShortcut") == nil)
        #expect(defaults.object(forKey: "escapeCancelPressCount") == nil)

        defaults.set(3, forKey: "escapeCancelPressCount")
        defaults.set(false, forKey: "escapeCancelEnabled")
        #expect(settings.escapeCancelPressCount == 3)
        #expect(!settings.escapeCancelEnabled)
    }

    @Test("T5-MIG-24 custom press counts survive")
    func customPressCountsSurvive() {
        let values = [
            "translateSelectedTextHotkeyPressCount": 2
        ]
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        let reloaded = SettingsStorage(defaults: defaults)
        #expect(reloaded.translateSelectedTextHotkeyPressCount == 2)
        #expect(reloaded.shortcutSetting(for: .translateSelectedText).pressCount == 2)
    }

    @Test("T5-MIG-25 push-to-talk settings survive")
    func pushToTalkSettingsSurvive() {
        defaults.set(PushToTalkKey.leftOption.rawValue, forKey: "pushToTalkKey")
        defaults.set(true, forKey: "pushToTalkToggleEnabled")
        defaults.set(3, forKey: "pushToTalkToggleTapCount")
        defaults.set(true, forKey: "pushToTalkHoldEnabled")
        defaults.set(1.7, forKey: "pushToTalkHoldStartDelaySeconds")
        defaults.set(PushToTalkKey.rightCommand.rawValue, forKey: "translationPushToTalkKey")
        defaults.set(false, forKey: "translationPushToTalkToggleEnabled")
        defaults.set(true, forKey: "translationPushToTalkHoldEnabled")
        defaults.set(0.8, forKey: "translationPushToTalkHoldStartDelaySeconds")

        let reloaded = SettingsStorage(defaults: defaults)
        #expect(PushToTalkConfigurator.dictation(reloaded) == .init(
            key: .leftOption, hold: true, toggle: true, tapCount: 3, holdDelay: 1.7
        ))
        let translation = PushToTalkConfigurator.translation(reloaded)
        #expect(translation.key == .rightCommand)
        #expect(!translation.toggle)
        #expect(translation.hold)
        #expect(translation.holdDelay == 0.8)
    }

    @Test("T5-MIG-26 legacy hands-free fallback reads as today")
    func legacyHandsFreeFallback() {
        defaults.set(true, forKey: "handsFreeModeEnabled")
        let reloaded = SettingsStorage(defaults: defaults)
        #expect(reloaded.pushToTalkToggleEnabled)
        #expect(!reloaded.pushToTalkHoldEnabled)
        #expect(reloaded.translationPushToTalkToggleEnabled == (reloaded.translationPushToTalkKey != .none))
        #expect(!reloaded.translationPushToTalkHoldEnabled)
    }

    @Test("T5-MIG-23 settings start-up leaves the package's shortcut storage alone")
    func packageStorageUntouched() {
        let stored = #"{"carbonKeyCode":40,"carbonModifiers":2304}"#
        defaults.set(stored, forKey: "KeyboardShortcuts_toggleRecording")
        _ = SettingsStorage(defaults: defaults)
        _ = SettingsStorage(defaults: defaults)
        #expect(defaults.string(forKey: "KeyboardShortcuts_toggleRecording") == stored)
    }

    // MARK: - Rows

    @Test("Every Shortcuts row has keys, a press count and a switch, with today's defaults")
    func rowsHaveDefaults() {
        #expect(settings.shortcutSetting(for: .cancelRecording)
            == ShortcutSetting(keys: .cancelKey(.defaultShortcut), pressCount: 2, enabled: true))
        #expect(settings.shortcutSetting(for: .forceSubmit)
            == ShortcutSetting(keys: .chord(.forceSubmit), pressCount: 1, enabled: true))
        #expect(settings.shortcutSetting(for: .addMeetingChapter)
            == ShortcutSetting(keys: .chord(.addMeetingChapter), pressCount: 1, enabled: true))
        #expect(settings.shortcutSetting(for: .translateSelectedText)
            == ShortcutSetting(keys: .chord(.translateSelectedText), pressCount: 1, enabled: true))
        #expect(settings.shortcutSetting(for: .inplaceTranslation)
            == ShortcutSetting(keys: .inplace(.modifierChord(Self.optionCommand)), pressCount: 2, enabled: true))
        #expect(settings.shortcutSetting(for: .historyPalette)
            == ShortcutSetting(keys: .chord(.toggleHistoryPalette), pressCount: 1, enabled: true))
        #expect(ShortcutRow.allCases.count == 6)
    }

    @Test("Switch off keeps the keys and the count", arguments: ShortcutRow.allCases)
    func offKeepsKeys(row: ShortcutRow) {
        settings.setShortcutPressCount(3, for: row)
        let before = settings.shortcutSetting(for: row)
        settings.setShortcutEnabled(false, for: row)
        let after = settings.shortcutSetting(for: row)

        #expect(!after.enabled)
        #expect(after.keys == before.keys)
        #expect(after.pressCount == before.pressCount)

        settings.setShortcutEnabled(true, for: row)
        #expect(settings.shortcutSetting(for: row) == before)
    }

    @Test("Press counts are 1 to 3", arguments: ShortcutRow.allCases)
    func pressCountRange(row: ShortcutRow) {
        if row == .inplaceTranslation {
            settings.inplaceTranslationShortcut = .keyChord
        }
        for count in 1 ... 3 {
            settings.setShortcutPressCount(count, for: row)
            #expect(settings.shortcutSetting(for: row).pressCount == count)
        }
        settings.setShortcutPressCount(7, for: row)
        #expect((1 ... 3).contains(settings.shortcutSetting(for: row).pressCount))
    }

    @Test("1x is allowed for every row except an in-place modifier chord")
    func singlePressAllowed() {
        for row in ShortcutRow.allCases where row != .inplaceTranslation {
            #expect(settings.shortcutSetting(for: row).allowedPressCounts == 1 ... 3, "\(row)")
        }
        #expect(settings.shortcutSetting(for: .inplaceTranslation).allowedPressCounts == 2 ... 3)
        settings.inplaceTranslationShortcut = .keyChord
        #expect(settings.shortcutSetting(for: .inplaceTranslation).allowedPressCounts == 1 ... 3)
    }

    @Test("An in-place count of 1 reads 2 for a modifier chord and is not rewritten")
    func inplaceCountClampsOnRead() {
        settings.inplaceTranslationShortcut = .keyChord
        settings.inplaceTranslationPressCount = 1
        #expect(settings.inplaceTranslationPressCount == 1)

        settings.inplaceTranslationShortcut = .modifierChord(Self.optionCommand)
        #expect(settings.inplaceTranslationPressCount == 2)
        #expect(defaults.integer(forKey: "inplaceTranslationPressCount") == 1)
    }

    // MARK: - In-place storage (D8)

    @Test("The in-place value is tagged JSON")
    func inplaceTaggedJSON() throws {
        let modifier = try JSONEncoder().encode(InplaceTranslationShortcut.modifierChord(Self.optionCommand))
        let object = try #require(JSONSerialization.jsonObject(with: modifier) as? [String: Any])
        #expect(object["kind"] as? String == "modifierChord")
        #expect(object["modifiers"] as? UInt == NSEvent.ModifierFlags([.option, .command]).rawValue)

        let key = try JSONEncoder().encode(InplaceTranslationShortcut.keyChord)
        #expect(String(decoding: key, as: UTF8.self) == #"{"kind":"keyChord"}"#)
    }

    @Test("An untagged modifier object decodes as a modifier chord; bad values read the default")
    func inplaceDecoding() {
        let raw = NSEvent.ModifierFlags([.control, .option]).rawValue
        defaults.set(Data(#"{"modifiers":\#(raw)}"#.utf8), forKey: "inplaceTranslationShortcut")
        #expect(settings.inplaceTranslationShortcut == .modifierChord([.control, .option]))

        let single = NSEvent.ModifierFlags.option.rawValue
        defaults.set(Data(#"{"kind":"modifierChord","modifiers":\#(single)}"#.utf8), forKey: "inplaceTranslationShortcut")
        #expect(settings.inplaceTranslationShortcut == .default, "One family is not a chord")

        defaults.set(Data("nonsense".utf8), forKey: "inplaceTranslationShortcut")
        #expect(settings.inplaceTranslationShortcut == .default)
    }

    @Test("Saving a modifier chord clears the package chord; saving a key chord stores it there")
    func savingInplaceShortcut() {
        let registrar = FakeHotkeyRegistrar()
        let chord = KeyboardShortcuts.Shortcut(.i, modifiers: [.control, .option])

        settings.saveInplaceTranslationShortcut(keyChord: chord, registrar: registrar)
        #expect(settings.inplaceTranslationShortcut == .keyChord)
        #expect(registrar.getShortcut(for: .inplaceTranslation) == chord)

        settings.saveInplaceTranslationShortcut(modifiers: [.control, .option], registrar: registrar)
        #expect(settings.inplaceTranslationShortcut == .modifierChord([.control, .option]))
        #expect(registrar.calls.last == .setShortcut(.inplaceTranslation, nil))
        #expect(!registrar.isEnabled(.inplaceTranslation))
    }

    @Test("PTT reservations apply only to a modifier chord")
    func reservationsOnlyForModifierChord() {
        settings.pushToTalkKey = .leftOption
        settings.pushToTalkHoldEnabled = true
        settings.translationPushToTalkKey = .rightOption
        settings.translationPushToTalkHoldEnabled = true
        #expect(!settings.inplaceTranslationActive)

        settings.inplaceTranslationShortcut = .keyChord
        #expect(settings.inplaceTranslationReservedKeys.isEmpty)
        #expect(settings.inplaceTranslationActive)

        settings.inplaceTranslationShortcut = .modifierChord([.control, .command])
        #expect(settings.inplaceTranslationReservedKeys.isEmpty, "Option is not part of ⌃⌘")
        #expect(settings.inplaceTranslationActive)
    }
}
