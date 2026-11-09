import XCTest

/// Settings > Providers, the key popup and the language popups (test-plan T3-TB, T3-LP, T3-KEY; WP-56).
/// The key store is in memory (`--ui-testing-elevenlabs-key`); account calls are stubbed by
/// `DIDUNY_UI_TEST_ELEVENLABS_TEST`. Reaches the page through the sidebar until WP-90 adds `--ui-testing-open`.
final class ProvidersUITests: DidunyUITestCase {
    private var window: XCUIElement { app.windows["Diduny"] }

    private func openProviders(key: String, account: String = "works") {
        launchApp(
            onboardingCompleted: true,
            arguments: ["--ui-testing-elevenlabs-key=\(key)"],
            environment: ["DIDUNY_UI_TEST_ELEVENLABS_TEST": account]
        )
        waitForElement(window.buttons["Sidebar Providers"]).click()
        waitForElement(window.descendants(matching: .any)["providers.table"])
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    // T3-TB-01
    func test_withKey_tableHasFiveColumnsAndNoAddSection() {
        openProviders(key: "present")
        for id in ["diduny-cloud", "elevenlabs", "local-whisper", "parakeet-v3", "apple-speech"] {
            waitForElement(element("providers.header.\(id)"))
        }
        waitForElement(element("providers.yourKey"))
        XCTAssertFalse(element("providers.addKey").exists)
        waitForElement(element("providers.cell.meetLabels.elevenlabs"),
                       toMatch: "label == 'ElevenLabs, Meeting speaker labels: Yes, After Stop, up to 32'")
        // Code fact (WP-11): the active Large v3 Turbo does not translate itself, so Whisper is By Diduny only.
        waitForElement(element("providers.cell.dictTranslation.local-whisper"),
                       toMatch: "label == 'Whisper, Dictation translation: By Diduny'")
    }

    // T3-TB-02
    func test_withoutKey_noElevenLabsColumnAndAddSection() {
        openProviders(key: "absent")
        waitForElement(element("providers.addKey"))
        XCTAssertFalse(element("providers.header.elevenlabs").exists)
        waitForElement(element("providers.addKey.save"), toMatch: "isEnabled == false")
        XCTAssertTrue(app.staticTexts["ElevenLabs transcribes with your key and bills you. Audio and the key are not sent to Diduny."].exists)
    }

    // T3-TB-04
    func test_legendHasThreeItems() {
        openProviders(key: "absent")
        let legend = waitForElement(element("providers.legend"))
        XCTAssertTrue(legend.staticTexts["The engine does it"].exists)
        XCTAssertTrue(legend.staticTexts["Not available"].exists)
    }

    // T3-LP-01, T3-LP-04
    func test_languageButtonsOpenTheirPopup() {
        openProviders(key: "present")
        let expected = [
            "diduny-cloud": "60 languages", "elevenlabs": "94 languages", "local-whisper": "100 languages",
            "parakeet-v3": "25 languages", "apple-speech": "Set in macOS"
        ]
        for (id, subtitle) in expected {
            // The language row sits behind the Dock on the 768 pt CI screen (seen at y 721).
            let button = element("providers.languages.\(id)")
            scrollIntoView(button, in: window.scrollViews.firstMatch)
            button.click()
            let popup = waitForElement(element("popup.languages.\(id)"))
            XCTAssertTrue(popup.staticTexts[subtitle].exists, id)
            XCTAssertEqual(popup.descendants(matching: .any)["popup.search"].exists, id != "apple-speech", id)
            popup.typeKey(.escape, modifierFlags: [])
            waitForDisappearance(popup)
        }
    }

    // T3-LP-02
    func test_searchFiltersAndShowsNothingFound() {
        openProviders(key: "present")
        element("providers.languages.elevenlabs").click()
        let popup = waitForElement(element("popup.languages.elevenlabs"))
        let search = popup.descendants(matching: .any)["popup.search"]
        search.typeText("ukr")
        waitForElement(popup.descendants(matching: .any)["popup.item.uk"])
        XCTAssertFalse(popup.descendants(matching: .any)["popup.item.pl"].exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeText("zzz")
        waitForElement(popup.descendants(matching: .any)["popup.empty"])
    }

    // T3-KEY-01
    func test_addKeyShowsTheColumn() {
        openProviders(key: "absent")
        let field = waitForElement(element("providers.addKey.field"))
        field.click()
        field.typeText("fake-key-for-ui-test")
        element("providers.addKey.save").click()
        waitForElement(element("providers.yourKey"))
        XCTAssertFalse(element("providers.addKey.field").exists)
    }

    // T3-KEY-02
    func test_invalidKeyIsNotSaved() {
        openProviders(key: "absent", account: "invalid")
        let field = waitForElement(element("providers.addKey.field"))
        field.click()
        field.typeText("fake-key-for-ui-test")
        element("providers.addKey.save").click()
        waitForElement(app.staticTexts["ElevenLabs rejected this key. Check it and paste it again."])
        XCTAssertFalse(element("providers.header.elevenlabs").exists)
    }

    // T3-KEY-03, T3-KEY-07
    func test_keyPopupRowsAndRemoveAsksFirst() {
        openProviders(key: "present")
        element("providers.yourKey").click()
        let popup = waitForElement(element("popup.key"))
        waitForElement(popup.descendants(matching: .any)["key.connection"], toMatch: "value == 'Works'")
        XCTAssertTrue((popup.descendants(matching: .any)["key.masked"].value as? String)?.hasSuffix("4f2a") == true)
        // en_US groups digits with a comma; the prototype draws "12 400 of 100 000 credits".
        waitForElement(popup.descendants(matching: .any)["key.usage"], toMatch: "value == '12,400 of 100,000 credits'")
        let remove = popup.buttons["key.remove"]
        remove.click()
        waitForElement(popup.buttons["key.keep"])
        XCTAssertEqual(remove.label, "Remove the key")
        popup.buttons["key.keep"].click()
        waitForDisappearance(popup.buttons["key.keep"])
        XCTAssertEqual(popup.buttons["key.remove"].label, "Remove")
    }

    // T3-KEY-08 (per-job defaults; per-segment ones wait for WP-13)
    func test_removeTheKeyHidesTheColumn() {
        openProviders(key: "present")
        element("providers.yourKey").click()
        let popup = waitForElement(element("popup.key"))
        popup.buttons["key.remove"].click()
        popup.buttons["key.remove"].click()
        waitForDisappearance(popup)
        waitForElement(element("providers.addKey"))
        XCTAssertFalse(element("providers.header.elevenlabs").exists)
    }
}
