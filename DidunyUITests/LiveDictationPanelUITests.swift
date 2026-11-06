import XCTest

/// WP-30 live dictation panel (test-plan T1-DI-20 to 26, T1-SH-05, T1-SH-06). Needs the
/// `--ui-testing-open=livePanel.<job>` harness target; CI only.
final class LiveDictationPanelUITests: DidunyUITestCase {
    private func openLivePanel(_ job: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-proxyBaseURL", Self.unreachableProxyURL, "-SUEnableAutomaticChecks", "NO",
            "--ui-testing-reset", "-onboarding.completed", "YES", "-onboarding.version", "1",
            "--ui-testing-open=livePanel.\(job)",
        ] + extra
        app.launch()
        waitForElement(app.descendants(matching: .any)["livePanel.title"])
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// T1-DI-20
    func test_dictationPanelOpensWithSettingsDefaults() {
        let app = openLivePanel("dictation")
        XCTAssertEqual(element(app, "livePanel.title").label, "Dictating")
        XCTAssertEqual(element(app, "livePanel.output").value as? String, "Original")
        XCTAssertEqual(element(app, "livePanel.engine").label.contains("Diduny Cloud"), true)
        XCTAssertEqual(element(app, "livePanel.caption").label, "Text as you speak")
    }

    /// T1-DI-21
    func test_outputMenuSearchAndPick() {
        let app = openLivePanel("dictation")
        element(app, "livePanel.output").click()
        let search = waitForElement(element(app, "pickerMenu.search"))
        search.typeText("Ukr")
        element(app, "pickerMenu.row.lang.uk").click()
        waitForElement(element(app, "livePanel.title"), toMatch: "label == 'Translating'")
        XCTAssertEqual(element(app, "livePanel.output").value as? String, "Ukrainian")
        XCTAssertEqual(element(app, "livePanel.caption").label, "Live translation")
    }

    /// T1-DI-24
    func test_stopKeycapFollowsPushToTalk() {
        let app = openLivePanel("dictation", extra: [
            "-pushToTalkKey", "rightShift", "-pushToTalkToggleEnabled", "YES", "-pushToTalkToggleTapCount", "2",
        ])
        let value = element(app, "livePanel.stop").value as? String ?? ""
        XCTAssertTrue(value.contains("⇧ ×2"), value)
        XCTAssertTrue(value.contains("Cancel: Esc ×2"), value)
    }

    /// T1-DI-25
    func test_noBatteryWarningInDictation() {
        let app = openLivePanel("dictation", extra: ["--ui-testing-power=battery"])
        XCTAssertFalse(element(app, "livePanel.batteryWarning").exists)
    }

    /// T1-DI-26
    func test_copyCopiesTheLiveText() {
        let app = openLivePanel("dictation")
        let copy = element(app, "livePanel.copy")
        waitForElement(copy, toMatch: "isEnabled == true")
        copy.click()
        waitForElement(copy, toMatch: "label == 'Copied'")
        XCTAssertFalse((NSPasteboard.general.string(forType: .string) ?? "").isEmpty)
    }

    /// T1-SH-05
    func test_stopButtonInAllFourLivePanels() {
        let keycaps = ["dictation": "⌥⌘D", "dictationTranslation": "⌥⌘/", "meeting": "⌥⌘M", "meetingTranslation": "⇧⌥⌘M"]
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
        let app = openLivePanel("dictation", extra: ["-escapeCancelEnabled", "NO"])
        let value = element(app, "livePanel.stop").value as? String ?? ""
        XCTAssertFalse(value.contains("Cancel:"), value)
    }
}
