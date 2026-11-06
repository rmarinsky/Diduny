import XCTest

/// Settings > Audio (test-plan T5-AU-02, -04, -05, -06). Needs WP-50 to route the "Audio" sidebar
/// item to `AudioSettingsView`. Store and session probe assertions (T5-AU-01, -03, -04, -06,
/// T5-AP-01) wait for the bridge and probe helpers (`DidunyUITests/Support/`), which do not exist yet.
final class AudioUITests: DidunyUITestCase {
    private var mainWindow: XCUIElement { app.windows["Diduny"] }

    private func element(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)[id]
    }

    private func openAudio() {
        launchApp(onboardingCompleted: true)
        waitForElement(mainWindow)
        let item = waitForElement(mainWindow.buttons["Sidebar Audio"])
        item.click()
        waitForElement(element("section.audioDictation"))
    }

    private func click(_ element: XCUIElement) {
        waitForElement(element, toMatch: "isHittable == true")
        element.click()
    }

    func test_microphoneTestTogglesLabels() {
        openAudio()
        let record = waitForElement(element("audio.mic.record"))
        XCTAssertEqual(record.title, "Record")
        click(record)
        waitForElement(record, toMatch: "title == 'Stop Recording'")
        waitForElement(element("audio.mic.level"), toMatch: "value != '0%'")
        click(record)
        waitForElement(record, toMatch: "title == 'Record'")
        let play = element("audio.mic.play")
        waitForElement(play, toMatch: "isEnabled == true")
        click(play)
        waitForElement(play, toMatch: "title == 'Stop'")
        click(play)
        waitForElement(play, toMatch: "title == 'Play'")
    }

    func test_levelSlidersShowPercent() {
        openAudio()
        let source = waitForElement(element("audio.meeting.source"))
        click(source.radioButtons["System + microphone"])
        waitForElement(element("audio.meeting.micLevel")).adjust(toNormalizedSliderPosition: 0.75)
        waitForElement(element("audio.meeting.micLevel.value"), toMatch: "value == '150%'")
        waitForElement(element("audio.meeting.systemLevel")).adjust(toNormalizedSliderPosition: 0.5)
        waitForElement(element("audio.meeting.systemLevel.value"), toMatch: "value == '100%'")
    }

    func test_systemOnlyHidesMicrophoneLevel() {
        openAudio()
        let source = waitForElement(element("audio.meeting.source"))
        click(source.radioButtons["System audio only"])
        waitForDisappearance(element("audio.meeting.micLevel"))
        waitForElement(element("audio.meeting.systemLevel"))
    }

    func test_systemAudioTestTogglesLabels() {
        openAudio()
        let capture = waitForElement(element("audio.meeting.capture"))
        click(capture)
        waitForElement(capture, toMatch: "title == 'Stop Capture'")
        click(capture)
        waitForElement(capture, toMatch: "title == 'Capture'")
        let play = element("audio.meeting.play")
        waitForElement(play, toMatch: "isEnabled == true")
        click(play)
        waitForElement(play, toMatch: "title == 'Stop'")
    }

    func test_identifySpeakersOffHidesVoiceProfile() {
        openAudio()
        let identify = waitForElement(element("audio.speakers.identify"))
        waitForElement(element("audio.speakers.caption"))
        click(identify)
        waitForDisappearance(element("audio.voiceProfile.setUp"))
    }
}
