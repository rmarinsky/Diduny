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
        waitForElement(text("Dictating", identifier: "livePanel.title", in: app))
        XCTAssertEqual(element(app, "livePanel.output").value as? String, "Original")
        XCTAssertTrue(spoken(element(app, "livePanel.engine")).contains("Diduny Cloud"), spoken(element(app, "livePanel.engine")))
        waitForElement(text("Text as you speak", identifier: "livePanel.caption", in: app))
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
        waitForElement(text("Translating", identifier: "livePanel.title", in: app))
        XCTAssertEqual(element(app, "livePanel.output").value as? String, "Ukrainian")
        waitForElement(text("Live translation", identifier: "livePanel.caption", in: app))
    }

    /// T1-DI-24
    func test_stopKeycapFollowsPushToTalk() {
        let app = openLivePanel("dictation", profile: LaunchProfile.standard.seeding(defaults: [
            "pushToTalkKey": "rightShift", "pushToTalkToggleEnabled": true, "pushToTalkToggleTapCount": 2,
        ]))
        let value = element(app, "livePanel.stop").value as? String ?? ""
        XCTAssertTrue(value.contains("⇧ ×2"), value)
        XCTAssertTrue(value.contains("Cancel: Esc ×2"), value)
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
            XCTAssertTrue(value.contains("Cancel: Esc ×2"), "\(job): \(value)")
            app.terminate()
        }
    }

    /// T1-SH-06
    func test_noCancelHintWhenCancelIsOff() {
        let app = openLivePanel("dictation", profile: LaunchProfile.standard.seeding(defaults: ["escapeCancelEnabled": false]))
        let value = element(app, "livePanel.stop").value as? String ?? ""
        XCTAssertFalse(value.contains("Cancel:"), value)
    }
}
