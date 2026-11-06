import XCTest

/// Settings > General (test-plan T5-GE). Cases that need the `P-STD` probe harness assert only
/// what the UI shows until the harness lands; probe checks are marked TODO(harness).
final class GeneralSettingsUITests: DidunyUITestCase {
    private var mainWindow: XCUIElement { app.windows["Diduny"] }
    private func element(_ id: String) -> XCUIElement { mainWindow.descendants(matching: .any)[id] }

    private func openGeneral() {
        launchApp(onboardingCompleted: true)
        waitForElement(mainWindow.buttons["Sidebar General"]).click()
        waitForElement(element("section.general"))
    }

    /// T5-GE-01
    func test_generalPageShowsEveryRow() {
        openGeneral()
        let page = element("section.general")
        waitForElement(page.staticTexts["General"])
        waitForElement(page.staticTexts["How the app behaves, whatever the mode."])
        for heading in ["After a recording", "While recording", "History", "Help"] {
            waitForElement(page.staticTexts[heading], "Missing group \(heading)")
        }
        for id in ["general.appLanguage", "general.launchAtLogin", "general.autoPaste", "general.playSound",
                   "general.messageStyle", "general.surface.compactPanel", "general.surface.notch",
                   "general.openPanelOnStart", "general.keepDictation", "general.keepMeetings",
                   "general.deleteExpired", "general.setupGuide", "general.screenRecording.askAgain",
                   "general.typingSpeed", "general.typingTest"] {
            let control = waitForElement(element(id), "Missing \(id)")
            XCTAssertTrue(control.isHittable, "\(id) is not hittable")
        }
    }

    /// T5-GE-07 (UI part); TODO(harness): probe `recordingFeedbackSurface` and the live surface.
    func test_surfacePreviewsActAsRadioGroup() {
        openGeneral()
        let panel = element("general.surface.compactPanel")
        let notch = element("general.surface.notch")
        waitForElement(panel, toMatch: "isSelected == true")
        notch.click()
        waitForElement(notch, toMatch: "isSelected == true")
        waitForElement(panel, toMatch: "isSelected == false")
        waitForDisappearance(element("general.openPanelOnStart"))
        panel.click()
        waitForElement(panel, toMatch: "isSelected == true")
        waitForElement(element("general.openPanelOnStart"))
    }

    /// T5-GE-09 (UI part); TODO(harness): probe the stored retention policies.
    func test_retentionMenusOfferSixOptions() {
        openGeneral()
        element("general.keepDictation").click()
        for option in ["Never", "7 days", "30 days", "90 days", "1 year", "Forever"] {
            waitForElement(app.menuItems[option], "Missing option \(option)")
        }
        app.menuItems["7 days"].click()
        waitForElement(element("general.keepDictation"), toMatch: "value == '7 days'")
    }

    /// T5-GE-11
    func test_setupGuideOpensWelcomeWindow() {
        openGeneral()
        element("general.setupGuide").click()
        waitForElement(app.windows["Welcome to Diduny"])
    }

    /// T5-GE-13; "40 WPM" is the fresh-install default.
    func test_typingSpeedAndTypingTest() {
        openGeneral()
        waitForElement(element("general.typingSpeed"), toMatch: "value == '40 WPM'")
        element("general.typingTest").click()
        waitForElement(element("section.typingTest"))
    }
}
