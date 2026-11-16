import XCTest

/// WP-53 Settings > Languages (test-plan T5-LA-20, 21, 26, 27). Needs the "Sidebar Dictation" item, its
/// "Languages" tab and `section.languages`. T5-LA-22 to 25 and 28 wait for the seed, probe and bridge helpers (test-plan 7.4).
final class LanguagesUITests: DidunyUITestCase {
    private var mainWindow: XCUIElement { app.windows["Diduny"] }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func openLanguages() -> XCUIElement {
        launchApp(onboardingCompleted: true)
        let item = waitForElement(mainWindow.buttons["Sidebar Dictation"])
        item.click()
        waitForElement(element("section.tabs")).radioButtons["Languages"].click()
        return waitForElement(mainWindow.descendants(matching: .any)["section.languages"])
    }

    func test_T5LA20_pageShowsTheDefaults() {
        _ = openLanguages()
        waitForElement(element("languages.yours.row.en"))
        waitForElement(element("languages.yours.row.uk"))
        waitForElement(element("languages.defaultTarget"), toMatch: "value == 'English'")
        waitForElement(element("languages.pair"), toMatch: "value == 'Ukrainian ↔ English'")
        waitForElement(element("languages.voice.enabled"))
        waitForElement(element("languages.voice.position"))
        waitForElement(element("languages.voice.targets"))
    }

    func test_T5LA21_changeYourLanguagesAddsPolish() {
        _ = openLanguages()
        let change = waitForElement(element("languages.yours.change"))
        XCTAssertTrue(change.isHittable)
        change.click()
        let popup = waitForElement(element("popup.change.yourLanguages"))
        waitForElement(popup.staticTexts["Your languages"])
        waitForElement(popup.staticTexts["Shown first everywhere you pick a language"])
        waitForElement(element("popup.group.chosen"))
        let search = waitForElement(element("popup.search"))
        search.click()
        search.typeText("pol")
        let polish = waitForElement(element("popup.tick.pl"))
        polish.click()
        waitForElement(polish, toMatch: "value == '1'")
        popup.typeKey(.escape, modifierFlags: [])
        waitForDisappearance(popup)
        waitForElement(element("languages.yours.row.pl"))
    }

    func test_T5LA26_voiceCommandPositionsAndSwitch() {
        _ = openLanguages()
        let position = waitForElement(element("languages.voice.position"))
        for title in ["At the start and end", "At the end", "Anywhere"] {
            waitForElement(position.radioButtons[title])
        }
        position.radioButtons["Anywhere"].click()
        waitForElement(position.radioButtons["Anywhere"], toMatch: "value == 1")
        let toggle = waitForElement(element("languages.voice.enabled"))
        toggle.click()
        waitForElement(toggle, toMatch: "value == 0")
    }

    func test_T5LA27_popupSearchesAndClosesOnOutsideClick() {
        _ = openLanguages()
        waitForElement(element("languages.yours.change")).click()
        let popup = waitForElement(element("popup.change.yourLanguages"))
        let search = waitForElement(element("popup.search"))
        search.click()
        search.typeText("zzz")
        waitForElement(element("popup.empty"))
        // Outside the popup: the tab of the page already shown, so the click changes nothing else.
        let outside = element("section.tabs").radioButtons["Languages"]
        waitForElement(outside, toMatch: "isHittable == true")
        outside.click()
        waitForDisappearance(popup)
    }
}
