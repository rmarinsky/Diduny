import XCTest

/// WP-30 live dictation panel (test-plan T1-DI-20 to 26, T1-SH-05, T1-SH-06), opened with
/// `--ui-testing-open=livePanel.<job>` on profile `P-STD`; CI only.
final class LiveDictationPanelUITests: DidunyUITestCase {
    private func openLivePanel(_ job: String, profile: LaunchProfile = .standard, extra: [String] = []) -> XCUIApplication {
        let app = launchApp(onboardingCompleted: true, profile: profile, open: "livePanel.\(job)", arguments: extra)
        waitForElement(app.descendants(matching: .any)["livePanel.title"])
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// What the element says: its label and its value (SwiftUI text reads as the value).
    private func spoken(_ element: XCUIElement) -> String {
        "\(element.label) \(element.value as? String ?? "")"
    }

    /// T1-DI-20
    func test_dictationPanelOpensWithSettingsDefaults() {
        let app = openLivePanel("dictation")
        waitForText("Dictating", identifier: "livePanel.title", in: app)
        XCTAssertEqual(element(app, "livePanel.output").value as? String, "Original")
        XCTAssertTrue(spoken(element(app, "livePanel.engine")).contains("Diduny Cloud"), spoken(element(app, "livePanel.engine")))
        waitForText("Text as you speak", identifier: "livePanel.caption", in: app)
    }

    /// T1-DI-21
    func test_outputMenuSearchAndPick() {
        let app = openLivePanel("dictation")
        let output = element(app, "livePanel.output")
        waitForElement(output, toMatch: "isHittable == true")
        output.click()
        let search = waitForElement(element(app, "pickerMenu.search"))
        search.typeText("Ukr")
        let row = element(app, "pickerMenu.row.lang.uk")
        waitForElement(row, toMatch: "isHittable == true")
        row.click()
        waitForText("Translating", identifier: "livePanel.title", in: app)
        XCTAssertEqual(element(app, "livePanel.output").value as? String, "Ukrainian")
        waitForText("Live translation", identifier: "livePanel.caption", in: app)
    }

    /// T1-DI-24
    func test_stopKeycapFollowsPushToTalk() {
        let app = openLivePanel("dictation", profile: LaunchProfile.standard.seeding(defaults: [
            "pushToTalkKey": "rightShift", "pushToTalkToggleEnabled": true, "pushToTalkToggleTapCount": 2,
        ]))
        let value = element(app, "livePanel.stop").value as? String ?? ""
        XCTAssertTrue(value.contains("⇧ ×2"), value)
        XCTAssertTrue(value.contains("Cancel: Esc ×3"), value)
    }

    /// T1-DI-25
    func test_noBatteryWarningInDictation() {
        let app = openLivePanel("dictation", profile: .battery)
        XCTAssertFalse(element(app, "livePanel.batteryWarning").exists)
    }

    /// T1-DI-26
    func test_copyCopiesTheLiveText() {
        let app = openLivePanel("dictation")
        let copy = element(app, "livePanel.copy")
        waitForElement(copy, toMatch: "isEnabled == true AND isHittable == true")
        copy.click()
        waitForElement(copy, toMatch: "label == 'Copied'")
        XCTAssertFalse((NSPasteboard.general.string(forType: .string) ?? "").isEmpty)
    }

    /// T1-SH-05
    func test_stopButtonInAllFourLivePanels() {
        let keycaps = ["dictation": "⌥⌘D", "dictationTranslation": "⌥⌘/", "meeting": "⌥⌘M", "meetingTranslation": "⌥⇧⌘M"]
        for (job, keycap) in keycaps {
            let app = openLivePanel(job)
            let stop = element(app, "livePanel.stop")
            XCTAssertEqual(stop.label, "Stop")
            XCTAssertTrue(stop.isHittable)
            let value = stop.value as? String ?? ""
            XCTAssertTrue(value.contains(keycap), "\(job): \(value)")
            XCTAssertTrue(value.contains("Cancel: Esc ×3"), "\(job): \(value)")
            app.terminate()
        }
    }

    /// T1-SH-06
    func test_noCancelHintWhenCancelIsOff() {
        let app = openLivePanel("dictation", profile: LaunchProfile.standard.seeding(defaults: ["escapeCancelEnabled": false]))
        let value = element(app, "livePanel.stop").value as? String ?? ""
        XCTAssertFalse(value.contains("Cancel:"), value)
    }

    /// T1-DI-22 (WP-64): an engine without live text keeps the text so far and says the rest comes after Stop.
    /// Deviation from the test-plan row: Roman's 2026-11-09 brief keeps the text, so no calm box with text.
    func test_engineMenuPickWithoutLiveText() {
        let app = openLivePanel("dictation")
        let engine = element(app, "livePanel.engine")
        waitForElement(engine, toMatch: "isHittable == true")
        engine.click()
        waitForElement(element(app, "pickerMenu.row.diduny-cloud"))
        let parakeet = element(app, "pickerMenu.row.parakeet-v3")
        waitForElement(parakeet, toMatch: "isHittable == true")
        parakeet.click()
        waitForText("Text after Stop", identifier: "livePanel.caption", in: app)
        waitForText("The rest of the text comes after Stop.", identifier: "livePanel.engineSwitchLine", in: app)
        XCTAssertTrue(spoken(element(app, "livePanel.engine")).contains("Parakeet V3"), spoken(element(app, "livePanel.engine")))
        XCTAssertTrue(element(app, "livePanel.copy").isEnabled)
    }

    /// WP-64: a live engine pick keeps the text and names the new engine.
    func test_engineMenuPickLiveEngineKeepsText() {
        let app = openLivePanel("dictation")
        let copy = element(app, "livePanel.copy")
        waitForElement(copy, toMatch: "isEnabled == true")
        element(app, "livePanel.engine").click()
        let apple = element(app, "pickerMenu.row.apple-speech")
        waitForElement(apple, toMatch: "isHittable == true")
        apple.click()
        waitForElement(element(app, "livePanel.engine"), toMatch: "value CONTAINS 'Apple Speech' OR label CONTAINS 'Apple Speech'")
        XCTAssertTrue(copy.isEnabled)
    }
}
