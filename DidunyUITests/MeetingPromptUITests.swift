import XCTest

/// T2-PR-20 to T2-PR-24: the meeting detected prompt (design-spec 7.8, 02 section 7).
/// The prompt appears only after a meeting is detected, which these cases trigger through the
/// test bridge (`meeting.detected app=Zoom`, test-plan 2.7). The bridge is not in the app yet,
/// so each case records that as its skip reason until it lands.
final class MeetingPromptUITests: DidunyUITestCase {
    private var prompt: XCUIElement { app.descendants(matching: .any)["commandPanel.prompt"] }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// `P-STD`, then the bridge posts `meeting.detected app=Zoom`. `seed` (for example
    /// `meetingTranscriptMode=localLive`) is applied by the bridge too, once WP-13 stores the key.
    private func showPrompt(seed _: [String: String] = [:]) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DIDUNY_UI_BRIDGE"] == "1",
            "Needs the test bridge command meeting.detected (test-plan 2.7)"
        )
        launchApp(freshInstall: true, onboardingCompleted: true)
        waitForElement(prompt, "The meeting prompt did not appear")
    }

    func test_T2_PR_20_promptAppearsPreset() throws {
        try showPrompt()
        XCTAssertEqual(element("prompt.title").label, "Looks like a meeting started")
        XCTAssertEqual(element("prompt.subtitle").label, "Record it?")
        XCTAssertTrue(element("prompt.segment.cloudLive").isSelected)
        let engine = element("prompt.engine")
        XCTAssertTrue((engine.value as? String ?? engine.label).contains("Diduny Cloud"))
        XCTAssertFalse(engine.isEnabled)
        XCTAssertEqual(element("prompt.keepSuggesting").value as? Int, 1)
    }

    func test_T2_PR_21_recordOnlyStartsThatMeeting() throws {
        try showPrompt()
        element("prompt.segment.recordOnly").click()
        let engine = element("prompt.engine")
        let text = engine.value as? String ?? engine.label
        XCTAssertTrue(text.contains("Transcript after Stop") && text.contains("Parakeet V3"), text)
        element("prompt.start").click()
        waitForElement(element("livePanel.title"), "The live meeting panel did not open")
    }

    func test_promptEngineIsPickedLikeTheLivePanel() throws {
        try showPrompt()
        element("prompt.segment.recordOnly").click()
        let engine = element("prompt.engine")
        waitForElement(engine, toMatch: "isHittable == true")
        XCTAssertTrue(engine.isEnabled, "Record only offers several engines, so the field is a menu")
        engine.click()
        let cloud = element("pickerMenu.row.diduny-cloud")
        waitForElement(cloud, toMatch: "isHittable == true")
        XCTAssertTrue(element("pickerMenu.row.parakeet-v3").exists)
        cloud.click()
        let text = engine.value as? String ?? engine.label
        XCTAssertTrue(text.contains("Diduny Cloud"), text)
    }

    func test_T2_PR_22_notNowCloseEscapeReturn() throws {
        for dismiss in ["prompt.notNow", "prompt.close", "escape"] {
            try showPrompt()
            if dismiss == "escape" { prompt.typeKey(.escape, modifierFlags: []) } else { element(dismiss).click() }
            waitForElement(prompt, toMatch: "exists == false")
            app.terminate()
        }
        try showPrompt()
        prompt.typeKey(.return, modifierFlags: [])
        waitForElement(element("livePanel.title"), "Return did not start the meeting")
    }

    func test_T2_PR_23_turningOffSuggestions() throws {
        try showPrompt()
        element("prompt.keepSuggesting").click()
        XCTAssertEqual(element("prompt.keepSuggesting").value as? Int, 0)
    }

    func test_T2_PR_24_promptFollowsStartsIn() throws {
        try showPrompt(seed: ["meetingTranscriptMode": "localLive"])
        XCTAssertTrue(element("prompt.segment.localLive").isSelected)
        let engine = element("prompt.engine")
        XCTAssertTrue((engine.value as? String ?? engine.label).contains("Whisper"))
    }
}
