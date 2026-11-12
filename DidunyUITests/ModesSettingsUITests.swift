import XCTest

/// Settings > Modes (test-plan 4.5). Navigation-only cases; the probe and bridge cases (T5-MD-21 to -39) need WP-90.
/// A fresh install is signed out, which is `P-OUT`.
final class ModesSettingsUITests: DidunyUITestCase {
    private var mainWindow: XCUIElement { app.windows["Diduny"] }

    private func element(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)[id]
    }

    private func openModes() -> XCUIElement {
        launchApp(onboardingCompleted: true)
        waitForElement(mainWindow.buttons["Sidebar Modes"]).click()
        return waitForElement(element("section.modes"), "Modes did not open")
    }

    /// T5-MD-20 (structure part) and T5-MD-29 (notice text).
    func test_modesPageShowsEveryRow() {
        let modes = openModes()
        waitForElement(modes.staticTexts["Modes & shortcuts"])
        waitForElement(modes.staticTexts["What runs each mode by default, how you start it, and the other shortcuts."])
        waitForElement(modes.staticTexts["You are signed out. Recording and translation by Diduny need an account."])
        for job in ["dictation", "dictationTranslation", "meeting", "meetingTranslation", "file"] {
            waitForElement(element("modes.row.\(job)"), "row \(job) missing")
            waitForElement(element("modes.\(job).engine"))
            waitForElement(element("modes.\(job).shortcut"))
        }
        waitForElement(element("modes.dictationTranslation.into"))
        waitForElement(element("modes.meeting.startsIn"))
        waitForElement(element("modes.meetingTranslation.between"))
        for job in ["dictation", "dictationTranslation", "meeting", "meetingTranslation", "file"] {
            XCTAssertFalse(element("modes.\(job).pressCount").exists)
        }
        XCTAssertFalse(element("modes.file.expand").exists)
    }

    /// T5-MD-27 (menu part).
    func test_filesEngineMenuListsOnlyEnginesOnThisMac() {
        _ = openModes()
        element("modes.file.engine").click()
        let menu = waitForElement(app.descendants(matching: .any)["pickerMenu"])
        waitForElement(menu.descendants(matching: .any)["pickerMenu.row.local-whisper"])
        waitForElement(menu.descendants(matching: .any)["pickerMenu.row.apple-speech"])
        XCTAssertFalse(menu.descendants(matching: .any)["pickerMenu.row.diduny-cloud"].exists)
        XCTAssertFalse(menu.descendants(matching: .any)["pickerMenu.row.elevenlabs"].exists)
    }

    /// T5-MD-40.
    func test_footerLinkOpensProviders() {
        _ = openModes()
        element("modes.footer.providers").click()
        waitForElement(element("section.providers"))
    }

    /// T5-MD-29 (button part).
    func test_signInOpensAccount() {
        let modes = openModes()
        modes.buttons["Sign in"].click()
        waitForElement(element("section.account"))
    }

    /// T5-MD-41 and T5-MD-09.
    func test_oneExpanderOpenAtATime() {
        _ = openModes()
        let dictation = element("modes.dictation.expand")
        dictation.click()
        waitForElement(dictation, toMatch: "value == 'expanded'")
        waitForElement(element("modes.dictation.pttKey"))
        element("modes.meeting.expand").click()
        waitForElement(element("modes.meeting.expand"), toMatch: "value == 'expanded'")
        waitForElement(dictation, toMatch: "value == 'collapsed'")
        waitForElement(element("modes.meeting.calendar"))
    }
}
