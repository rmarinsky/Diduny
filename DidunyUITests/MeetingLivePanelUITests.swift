import XCTest

/// Meeting live panel (test-plan T1-MT-20, T1-MT-26, T1-A11Y-01; WP-31). Needs the test-plan 2.3 launch
/// arguments (`--ui-testing-open`, `--ui-testing-power`, stubs), which land with the UI test harness.
final class MeetingLivePanelUITests: DidunyUITestCase {
    private static let standard = [
        "--ui-testing-reset", "-onboarding.completed", "YES", "-onboarding.version", "1",
        "--ui-testing-signed-in", "--ui-testing-quota=available", "--ui-testing-stub-engines",
        "--ui-testing-stub-paste", "--ui-testing-fixed-clock=2026-11-06T10:00:00Z",
        "--ui-testing-command-panel-pinned", "--ui-testing-parakeet=downloaded",
        "--ui-testing-whisper-models=ggml-large-v3-turbo:active", "--ui-testing-elevenlabs-key=absent",
        "--ui-testing-apple-speech=available", "--ui-testing-input-bridge", "--ui-testing-probe",
    ]

    private func open(_ target: String, power: String = "ac") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-proxyBaseURL", DidunyUITestCase.unreachableProxyURL,
                               "-SUEnableAutomaticChecks", "NO"]
            + Self.standard + ["--ui-testing-power=\(power)", "--ui-testing-open=\(target)"]
        app.launch()
        return app
    }

    /// T1-MT-20
    func testOpensOnTheSettingsSegment() {
        let app = open("livePanel.meeting")
        waitForElement(text("Recording meeting", identifier: "livePanel.title", in: app))
        let cloud = waitForElement(app.buttons["livePanel.segment.cloudLive"])
        XCTAssertTrue(cloud.isSelected)
        let engine = app.descendants(matching: .any)["livePanel.engine"]
        waitForElement(engine)
        XCTAssertTrue((engine.value as? String ?? engine.label).contains("Diduny Cloud"))
        XCTAssertFalse(engine.isEnabled)
        waitForElement(text("Live text · speaker labels", identifier: "livePanel.caption", in: app))
        let status = app.descendants(matching: .any)["livePanel.status"]
        waitForElement(status, toMatch: "label == 'Recording live'")
    }

    /// T1-MT-26
    func testNoBatteryWarningOutsideThisMac() {
        let app = open("livePanel.meeting", power: "battery")
        waitForElement(app.buttons["livePanel.segment.cloudLive"])
        XCTAssertFalse(app.descendants(matching: .any)["livePanel.batteryWarning"].exists)
        app.buttons["livePanel.segment.recordOnly"].click()
        waitForElement(app.descendants(matching: .any)["livePanel.calm"])
        XCTAssertFalse(app.descendants(matching: .any)["livePanel.batteryWarning"].exists)
        app.buttons["livePanel.segment.localLive"].click()
        waitForElement(app.descendants(matching: .any)["livePanel.batteryWarning"])
    }

    /// T1-A11Y-01
    func testAccessibility() {
        let app = open("livePanel.meeting")
        let group = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Transcript mode'")).firstMatch
        waitForElement(group)
        XCTAssertTrue(app.buttons["livePanel.segment.cloudLive"].isSelected)
        XCTAssertFalse(app.buttons["livePanel.segment.localLive"].isSelected)
        XCTAssertFalse(app.buttons["livePanel.segment.recordOnly"].isSelected)
        let minimize = app.buttons["livePanel.minimize"]
        waitForElement(minimize, toMatch: "label == 'Hide recording panel'")
    }
}
