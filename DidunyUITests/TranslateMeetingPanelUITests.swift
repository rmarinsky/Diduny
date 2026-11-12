import XCTest

/// Translate meeting live panel (test-plan T1-TM-20 to T1-TM-23), opened with
/// `--ui-testing-open=livePanel.meetingTranslation` on profile `P-STD`; CI only.
final class TranslateMeetingPanelUITests: DidunyUITestCase {
    private func openPanel(profile: LaunchProfile = .standard, extra: [String] = []) -> XCUIApplication {
        let app = launchApp(onboardingCompleted: true, profile: profile, open: "livePanel.meetingTranslation", arguments: extra)
        waitForElement(app.descendants(matching: .any)["livePanel.title"])
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func click(_ element: XCUIElement) {
        waitForElement(element, toMatch: "isHittable == true")
        element.click()
    }

    func test_T1_TM_20_opensLive() {
        let app = openPanel()
        waitForText("Translating meeting", identifier: "livePanel.title", in: app)
        XCTAssertEqual(app.buttons["livePanel.between"].value as? String, "UK ↔ EN")
        let engine = element(app, "livePanel.engine")
        XCTAssertTrue("\(engine.label) \(engine.value as? String ?? "")".contains("Diduny Cloud"))
        waitForText("Live · both directions · speaker labels", identifier: "livePanel.caption", in: app)
        XCTAssertEqual(app.buttons["livePanel.showOriginal"].label, "Show original text")
        XCTAssertEqual(element(app, "livePanel.status").value as? String, "live")
    }

    func test_T1_TM_21_showAndHideOriginalText() {
        let app = openPanel(extra: ["--ui-testing-transcript-emit=2"])
        let link = waitForElement(app.buttons["livePanel.showOriginal"])
        let original = app.staticTexts.matching(identifier: "livePanel.originalLine").firstMatch
        XCTAssertFalse(original.exists)
        click(link)
        waitForElement(link, toMatch: "label == 'Hide original text'")
        waitForElement(original)
        click(link)
        waitForDisappearance(original)
    }

    func test_T1_TM_22_betweenPickChangesThePair() {
        // Between offers the pairs of Your languages; Polish must be one of them.
        let app = openPanel(profile: LaunchProfile.standard.seeding(defaults: ["yourLanguages": ["en", "uk", "pl"]]))
        click(waitForElement(app.buttons["livePanel.between"]))
        click(waitForElement(element(app, "pickerMenu.row.pair.en-pl")))
        waitForElement(app.buttons["livePanel.between"], toMatch: "value == 'EN ↔ PL'")
    }

    func test_T1_TM_23_otherLanguagesOpensSettingsLanguages() {
        let app = openPanel()
        click(waitForElement(app.buttons["livePanel.between"]))
        click(waitForElement(element(app, "pickerMenu.row.otherLanguages")))
        waitForElement(element(app, "section.languages"))
    }

    /// Meeting translation is cloud only: engines on this Mac are not offered.
    func test_T1_TM_24_engineMenuOffersOnlyCloudEngines() {
        let app = openPanel()
        click(waitForElement(element(app, "livePanel.engine")))
        waitForElement(element(app, "pickerMenu.row.diduny-cloud"))
        for id in ["local-whisper", "parakeet-v3", "apple-speech"] {
            XCTAssertFalse(element(app, "pickerMenu.row.\(id)").exists, id)
        }
    }
}
