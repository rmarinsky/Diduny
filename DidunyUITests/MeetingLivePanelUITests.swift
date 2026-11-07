import XCTest

/// Meeting live panel (test-plan T1-MT-20, T1-MT-26, T1-A11Y-01; WP-31), opened with
/// `--ui-testing-open=livePanel.meeting` on profile `P-STD`; CI only.
final class MeetingLivePanelUITests: DidunyUITestCase {
    private func open(_ target: String, profile: LaunchProfile = .standard) -> XCUIApplication {
        launchApp(onboardingCompleted: true, profile: profile, open: target)
    }

    /// T1-MT-20
    func testOpensOnTheSettingsSegment() {
        let app = open("livePanel.meeting")
        waitForText("Recording meeting", identifier: "livePanel.title", in: app)
        let cloud = waitForElement(app.buttons["livePanel.segment.cloudLive"])
        XCTAssertTrue(cloud.isSelected)
        let engine = app.descendants(matching: .any)["livePanel.engine"]
        waitForElement(engine)
        XCTAssertTrue("\(engine.label) \(engine.value as? String ?? "")".contains("Diduny Cloud"))
        XCTAssertFalse(engine.isEnabled)
        waitForText("Live text · speaker labels", identifier: "livePanel.caption", in: app)
        let status = app.descendants(matching: .any)["livePanel.status"]
        waitForElement(status, toMatch: "label == 'Recording live'")
    }

    /// T1-MT-26
    func testNoBatteryWarningOutsideThisMac() throws {
        try XCTSkipIf(true, "Needs mid-meeting segment switching (WP-63): segments are locked to the running one")
        let app = open("livePanel.meeting", profile: .battery)
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
