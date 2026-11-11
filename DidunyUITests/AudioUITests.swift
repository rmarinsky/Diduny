import XCTest

/// Settings > Audio (test-plan T5-AU-02, -04, -05, -06). Needs WP-50 to route the "Audio" sidebar
/// item to `AudioSettingsView`. Store and session probe assertions (T5-AU-01, -03, -04, -06,
/// T5-AP-01) wait for the bridge and probe helpers (`DidunyUITests/Support/`), which do not exist yet.
final class AudioUITests: DidunyUITestCase {
    private var mainWindow: XCUIElement { app.windows["Diduny"] }

    private func element(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)[id]
    }

    /// `P-STD` with fake input devices: no microphone or Screen Recording on CI; recording yields
    /// silence at a steady 0.5 level (test-plan 4.8).
    private func openAudio() {
        launchApp(onboardingCompleted: true, profile: LaunchProfile.standard.adding("--ui-testing-audio-devices=Test Mic A,Test Mic B"))
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
        XCTAssertEqual(record.label, "Record")
        click(record)
        waitForElement(record, toMatch: "label == 'Stop Recording'")
        waitForElement(element("audio.mic.level"), toMatch: "value != '0%'")
        click(record)
        waitForElement(record, toMatch: "label == 'Record'")
        let play = element("audio.mic.play")
        waitForElement(play, toMatch: "isEnabled == true")
        click(play)
        waitForElement(play, toMatch: "label == 'Stop'")
        click(play)
        waitForElement(play, toMatch: "label == 'Play'")
    }

    /// `GapSlider` is a custom view, not an NSSlider, so XCUI can't `adjust` it: click at the target
    /// point instead (a zero-distance drag sets the value). Pixel rounding can land one 5 % step off.
    /// "150%" and "100%" themselves are `AudioSettingsTextTests`.
    private func adjust(_ id: String, to position: CGFloat, near percent: Int) {
        let slider = waitForElement(element(id))
        slider.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).click()
        let label = element("\(id).value")
        let allowed = [percent - 5, percent, percent + 5].map { "'\($0)%'" }.joined(separator: ",")
        waitForElement(label, toMatch: "value IN {\(allowed)}")
    }

    func test_levelSlidersShowPercent() {
        openAudio()
        let source = waitForElement(element("audio.meeting.source"))
        click(source.radioButtons["System + microphone"])
        adjust("audio.meeting.micLevel", to: 0.75, near: 150)
        // 0.5 is today's value (100%); move away first so the drag to 0.5 is a real change.
        adjust("audio.meeting.systemLevel", to: 0.25, near: 50)
        adjust("audio.meeting.systemLevel", to: 0.5, near: 100)
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
        waitForElement(capture, toMatch: "label == 'Stop Capture'")
        click(capture)
        waitForElement(capture, toMatch: "label == 'Capture'")
        let play = element("audio.meeting.play")
        waitForElement(play, toMatch: "isEnabled == true")
        click(play)
        waitForElement(play, toMatch: "label == 'Stop'")
    }

    func test_identifySpeakersOffHidesVoiceProfile() {
        openAudio()
        let identify = waitForElement(element("audio.speakers.identify"))
        waitForElement(element("audio.speakers.caption"))
        click(identify)
        waitForDisappearance(element("audio.voiceProfile.setUp"))
    }
}
