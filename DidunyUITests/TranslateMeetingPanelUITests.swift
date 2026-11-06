import XCTest

/// Translate meeting live panel (test-plan T1-TM-20 to T1-TM-23). Needs the `--ui-testing-open=livePanel.<job>`
/// target and the transcript bridge (test-plan 7.4); CI only.
final class TranslateMeetingPanelUITests: DidunyUITestCase {
    private var panelApp: XCUIApplication!

    override func tearDownWithError() throws {
        panelApp?.terminate()
        try super.tearDownWithError()
    }

    private func openPanel(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-proxyBaseURL", Self.unreachableProxyURL, "-SUEnableAutomaticChecks", "NO",
            "--ui-testing-reset", "-onboarding.completed", "YES", "-onboarding.version", "1",
            "--ui-testing-open=livePanel.meetingTranslation",
        ] + extra
        app.launch()
        panelApp = app
        return app
    }

    func test_T1_TM_20_opensLive() {
        let app = openPanel()
        XCTAssertEqual(waitForElement(app.staticTexts["livePanel.title"]).label, "Translating meeting")
        XCTAssertEqual(app.buttons["livePanel.between"].value as? String, "EN ↔ UK")
        XCTAssertEqual(app.buttons["livePanel.engine"].value as? String, "Diduny Cloud")
        XCTAssertEqual(app.staticTexts["livePanel.caption"].label, "Live · both directions · speaker labels")
        XCTAssertEqual(app.buttons["livePanel.showOriginal"].label, "Show original text")
        XCTAssertEqual(app.descendants(matching: .any)["livePanel.status"].value as? String, "live")
    }

    func test_T1_TM_21_showAndHideOriginalText() {
        let app = openPanel(extra: ["--ui-testing-transcript-emit=2"])
        let link = waitForElement(app.buttons["livePanel.showOriginal"])
        XCTAssertEqual(app.staticTexts.matching(identifier: "livePanel.originalLine").count, 0)
        link.click()
        XCTAssertEqual(link.label, "Hide original text")
        XCTAssertGreaterThan(app.staticTexts.matching(identifier: "livePanel.originalLine").count, 0)
        link.click()
        XCTAssertEqual(app.staticTexts.matching(identifier: "livePanel.originalLine").count, 0)
    }

    func test_T1_TM_22_betweenPickChangesThePair() {
        let app = openPanel()
        waitForElement(app.buttons["livePanel.between"]).click()
        waitForElement(app.descendants(matching: .any)["pickerMenu.row.pair.en-pl"]).click()
        XCTAssertEqual(app.buttons["livePanel.between"].value as? String, "EN ↔ PL")
    }

    func test_T1_TM_23_otherLanguagesOpensSettingsLanguages() {
        let app = openPanel()
        waitForElement(app.buttons["livePanel.between"]).click()
        waitForElement(app.descendants(matching: .any)["pickerMenu.row.otherLanguages"]).click()
        waitForElement(app.descendants(matching: .any)["section.languages"])
    }
}
