import AppKit
import XCTest

/// Meeting live panel (test-plan T1-MT-20, T1-MT-26, T1-A11Y-01; WP-31), opened with
/// `--ui-testing-open=livePanel.meeting` on profile `P-STD`; CI only.
final class MeetingLivePanelUITests: DidunyUITestCase {
    private func open(_ target: String, profile: LaunchProfile = .standard, arguments: [String] = []) -> XCUIApplication {
        launchApp(onboardingCompleted: true, profile: profile, open: target, arguments: arguments)
    }

    /// A transcript line's text; macOS may expose it as label or as value.
    private func text(_ element: XCUIElement) -> String {
        "\(element.label) \(element.value as? String ?? "")"
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
    func testNoBatteryWarningOutsideThisMac() {
        // No text: the calm box. With text, Record only keeps the transcript (design decision, 2026-11-09).
        let app = open("livePanel.meeting", profile: .battery, arguments: ["--ui-testing-transcript-emit=0"])
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
        let recordOnly = app.buttons["livePanel.segment.recordOnly"]
        XCTAssertFalse(recordOnly.isSelected)
        // Roman's DEV: Record only fell off the panel's right edge.
        XCTAssertTrue(recordOnly.isHittable)
        XCTAssertGreaterThan(recordOnly.frame.width, 60)
        let minimize = app.buttons["livePanel.minimize"]
        waitForElement(minimize, toMatch: "label == 'Hide recording panel'")
    }

    /// T1-MT-21
    func test_T1_MT_21_everySegmentIsClickable() {
        let app = open("livePanel.meeting")
        app.buttons["livePanel.segment.localLive"].click()
        waitForElement(app.staticTexts["livePanel.marker"])
        XCTAssertTrue(text(app.staticTexts["livePanel.marker"]).contains("switched to Local"))
        waitForText("Live text (preview) · no speaker labels", identifier: "livePanel.caption", in: app)
        bridge("clock.advance", ["seconds": 5])
        app.buttons["livePanel.segment.recordOnly"].click()
        waitForElement(app.buttons["livePanel.segment.recordOnly"], toMatch: "isSelected == true")
        let status = app.descendants(matching: .any)["livePanel.status"]
        waitForElement(status, toMatch: "label == 'Recording, no live text'")
        // Text stays on Record only and Copy works (Roman, 2026-11-09).
        waitForElement(app.descendants(matching: .any)["livePanel.gapNote"])
        XCTAssertTrue(app.buttons["livePanel.copy"].isEnabled)
        app.buttons["livePanel.segment.cloudLive"].click()
        waitForElement(app.buttons["livePanel.segment.cloudLive"], toMatch: "isSelected == true")
        XCTAssertEqual(probe()["session"].flatMap { ($0 as? [String: Any])?["segment"] as? String }, MeetingSegmentRaw.cloud)
    }

    /// T1-MT-22
    func test_T1_MT_22_localEngineMenuSwitches() {
        let app = open("livePanel.meeting.localLive")
        let engine = waitForElement(app.buttons["livePanel.engine"])
        engine.click()
        let apple = app.descendants(matching: .any)["pickerMenu.row.apple-speech"]
        waitForElement(apple)
        apple.click()
        waitForText("Live text · no speaker labels", identifier: "livePanel.caption", in: app)
        waitForElement(app.staticTexts["livePanel.marker"])
        XCTAssertTrue(text(app.staticTexts["livePanel.marker"]).contains("switched to Apple Speech"))
    }

    /// T1-MT-24
    func test_T1_MT_24_cloudEngineSwitch() {
        let app = open("livePanel.meeting", profile: LaunchProfile.standard.adding("--ui-testing-elevenlabs-key=present"))
        let engine = waitForElement(app.buttons["livePanel.engine"])
        engine.click()
        let row = app.descendants(matching: .any)["pickerMenu.row.elevenlabs"]
        waitForElement(row)
        row.click()
        waitForText("Live text · no speaker labels", identifier: "livePanel.caption", in: app)
        XCTAssertTrue(text(waitForElement(app.staticTexts["livePanel.marker"])).contains("switched to ElevenLabs"))
    }

    /// T1-MT-25
    func test_T1_MT_25_batteryLinkSwitchesToCloud() {
        let app = open("livePanel.meeting.localLive", profile: .battery)
        waitForElement(app.descendants(matching: .any)["livePanel.batteryWarning"])
        let link = app.descendants(matching: .any)["livePanel.useCloud"]
        waitForElement(link)
        bridge("meeting.useCloud")
        waitForElement(app.buttons["livePanel.segment.cloudLive"], toMatch: "isSelected == true")
        XCTAssertFalse(app.descendants(matching: .any)["livePanel.batteryWarning"].exists)
        app.buttons["livePanel.segment.localLive"].click()
        waitForElement(app.descendants(matching: .any)["livePanel.batteryWarning"])
        bridge("power", ["source": "ac"])
        waitForDisappearance(app.descendants(matching: .any)["livePanel.batteryWarning"])
    }

    /// T1-A11Y-02
    func test_T1_A11Y_02_arrowMovesAcrossGroups() {
        let app = open("livePanel.meeting")
        let cloud = waitForElement(app.buttons["livePanel.segment.cloudLive"])
        cloud.click()
        cloud.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(cloud.isSelected, "An arrow moves focus only; it must not switch")
        cloud.typeKey(.return, modifierFlags: [])
        waitForElement(app.buttons["livePanel.segment.recordOnly"], toMatch: "isSelected == true")
    }

    /// Marker pair (ADR-0013 risks): the line shows in the panel and stays out of Copy.
    func test_markerShowsInThePanel() {
        let app = open("livePanel.meeting")
        app.buttons["livePanel.segment.recordOnly"].click()
        let marker = waitForElement(app.staticTexts["livePanel.marker"])
        XCTAssertTrue(text(marker).contains("switched to Record only"), text(marker))
    }

    func test_markerStaysOutOfCopy() {
        let app = open("livePanel.meeting")
        app.buttons["livePanel.segment.recordOnly"].click()
        waitForElement(app.staticTexts["livePanel.marker"])
        NSPasteboard.general.clearContents()
        app.buttons["livePanel.copy"].click()
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertFalse(copied.isEmpty)
        XCTAssertFalse(copied.contains("switched to"))
    }
}

private enum MeetingSegmentRaw {
    static let cloud = "cloud"
}
