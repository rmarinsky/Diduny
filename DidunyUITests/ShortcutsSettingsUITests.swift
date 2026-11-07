import XCTest

/// WP-55: Settings > Shortcuts (test-plan T5-SC-*, real-key twins of the bridge cases, §3.2).
/// T5-HK-00 passed, so chords are sent with `typeKey`; modifier-only and side-specific keys stay
/// on the bridge (WP-90) and are not here.
final class ShortcutsSettingsUITests: DidunyUITestCase {
    private var mainWindow: XCUIElement { app.windows["Diduny"] }

    private func element(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)[id]
    }

    private func openShortcuts(arguments: [String] = []) {
        launchApp(freshInstall: true, onboardingCompleted: true, arguments: arguments)
        waitForElement(mainWindow, "Main window did not open")
        mainWindow.buttons["Sidebar Shortcuts"].click()
        waitForElement(element("shortcuts.forceSubmit.keys"), "Shortcuts page did not open")
    }

    private static let rows = [
        "escapeCancel", "forceSubmit", "addMeetingChapter", "translateSelectedText", "inplaceTranslation",
        "toggleHistoryPalette",
    ]

    /// T5-SC-01: rows and defaults. Values are spoken as spec 4.14 says ("Option Command B").
    func test_SC01_rowsAndDefaults() {
        openShortcuts()
        for heading in ["While recording", "Text", "App"] {
            waitForElement(mainWindow.staticTexts[heading])
        }
        let defaults = [
            "escapeCancel": "Escape", "forceSubmit": "Command Return", "addMeetingChapter": "Option Command B",
            "translateSelectedText": "Option Command T", "inplaceTranslation": "Option Command",
            "toggleHistoryPalette": "Option Command H",
        ]
        for (row, value) in defaults {
            waitForElement(element("shortcuts.\(row).keys"), toMatch: "value == '\(value)'")
            waitForElement(element("shortcuts.\(row).enabled"), toMatch: "value == 1")
        }
        waitForElement(element("shortcuts.escapeCancelSaveAudio"), toMatch: "value == 1")
        waitForElement(element("shortcuts.inplaceTranslationPair"), toMatch: "value == 'English ↔ Ukrainian'")
        waitForElement(element("shortcuts.openSettings.keys"), toMatch: "value == 'Command ,'")
    }

    /// T5-SC-02: a switch off disables its keys and count and keeps the keys.
    func test_SC02_switchOffDisablesKeysAndCount() {
        openShortcuts()
        for row in Self.rows {
            let keys = element("shortcuts.\(row).keys")
            let value = keys.value as? String
            element("shortcuts.\(row).enabled").click()
            waitForElement(keys, toMatch: "isEnabled == false")
            waitForElement(element("shortcuts.\(row).pressCount"), toMatch: "isEnabled == false")
            XCTAssertEqual(keys.value as? String, value, "\(row): keys must be kept when off")
            element("shortcuts.\(row).enabled").click()
            waitForElement(keys, toMatch: "isEnabled == true")
        }
    }

    /// T5-SC-12: Open Settings cannot be changed.
    func test_SC12_openSettingsIsFixed() {
        openShortcuts()
        let keys = element("shortcuts.openSettings.keys")
        waitForElement(keys, toMatch: "isEnabled == false")
        waitForElement(mainWindow.staticTexts["The standard macOS shortcut. It cannot be changed."])
    }

    /// T5-SC-14 (UI half): 3× sticks on every row. The store half needs the WP-90 probe.
    func test_SC14_pressCountSelects() {
        openShortcuts()
        for row in Self.rows {
            let picker = element("shortcuts.\(row).pressCount")
            picker.radioButtons["3×"].click()
            waitForElement(picker.radioButtons["3×"], toMatch: "value == 1")
        }
    }

    /// In place with the default modifier chord: 1× is disabled (ADR-0012 D8).
    func test_inplaceModifierChordDisablesSinglePress() {
        openShortcuts()
        let picker = element("shortcuts.inplaceTranslation.pressCount")
        waitForElement(picker.radioButtons["2×"], toMatch: "value == 1")
        waitForElement(picker.radioButtons["1×"], toMatch: "isEnabled == false")
    }

    /// Acceptance: Escape while recording restores the old value.
    func test_escapeWhileRecordingKeepsOldValue() {
        openShortcuts(arguments: ["--ui-testing-probe"])
        let keys = element("shortcuts.addMeetingChapter.keys")
        keys.click()
        print("CAPTURE-PROBE escape:", probe()["capture"] ?? "none")
        waitForElement(keys, toMatch: "value == 'Press keys...'")
        app.typeKey(.escape, modifierFlags: [])
        waitForElement(keys, toMatch: "value == 'Option Command B'")
    }

    /// T5-SC-04 real-key twin with T5-HP-20: the new history shortcut opens the palette, the old one does not.
    func test_SC04_changeHistoryPaletteShortcut_realKeys() {
        openShortcuts(arguments: ["--ui-testing-probe"])
        let keys = element("shortcuts.toggleHistoryPalette.keys")
        keys.click()
        print("CAPTURE-PROBE sc04:", probe()["capture"] ?? "none")
        app.typeKey("h", modifierFlags: [.control, .option])
        waitForElement(keys, toMatch: "value == 'Control Option H'")

        let palette = app.windows["History"]
        app.typeKey("h", modifierFlags: [.command, .option])
        XCTAssertFalse(palette.waitForExistence(timeout: 2), "old ⌥⌘H must be unmatched")
        app.typeKey("h", modifierFlags: [.control, .option])
        waitForElement(palette, "new ⌃⌥H did not open the history palette")
    }

    /// T5-HP-20 real-key twin: ⌥⌘H opens, then hides the palette.
    func test_HP20_historyPaletteToggles_realKeys() {
        openShortcuts()
        let palette = app.windows["History"]
        app.typeKey("h", modifierFlags: [.command, .option])
        waitForElement(palette)
        app.typeKey("h", modifierFlags: [.command, .option])
        waitForDisappearance(palette)
    }
}
