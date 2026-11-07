import XCTest

/// Settings > Local models (test-plan 4.4). Cases that need fake downloads, a fake Whisper store or the
/// probe (`P-DL`, T4-X-02 to T4-X-09, T4-WO-01) wait for the WP-90 launch flags.
final class LocalModelsUITests: DidunyUITestCase {
    private var window: XCUIElement { app.windows["Diduny"] }

    private func element(_ id: String) -> XCUIElement {
        window.descendants(matching: .any)[id]
    }

    private func openLocalModels() {
        launchApp(onboardingCompleted: true)
        waitForElement(window.descendants(matching: .any)["section.overview"])
        window.buttons["Sidebar Local models"].click()
        waitForElement(element("models.table"))
    }

    /// T4-X-01 (the part without fake stores): lead, legend, speaker note, Apple Speech built in.
    func test_pageShowsLeadLegendAndNote() {
        openLocalModels()
        waitForElement(window.staticTexts["Run on this Mac. Audio never leaves it."])
        waitForElement(element("models.legend"))
        waitForElement(element("models.speakerNote"))
        waitForElement(element("models.action.apple-speech.builtIn"))
        waitForElement(element("models.action.ggml-base.download"))
    }

    /// T4-X-10.
    func test_sortByAccuracyPutsRecommendedFirst() {
        openLocalModels()
        let sort = waitForElement(element("models.sort"))
        sort.radioButtons["Accuracy"].click()
        let turbo = element("models.row.ggml-large-v3-turbo")
        let largeV3 = element("models.row.ggml-large-v3")
        waitForElement(turbo)
        XCTAssertLessThan(turbo.frame.minY, largeV3.frame.minY, "Recommended Large v3 Turbo sits above Large v3")
    }

    /// T4-X-11.
    func test_languagesCellsOpenTheirLists() {
        openLocalModels()
        let parakeet = waitForElement(element("models.cell.parakeet-v3.languages"))
        XCTAssertTrue(parakeet.isHittable)
        parakeet.click()
        waitForElement(app.descendants(matching: .any)["popup.languages.parakeet-v3"])
        app.typeKey(.escape, modifierFlags: [])
        waitForDisappearance(app.descendants(matching: .any)["popup.languages.parakeet-v3"])

        element("models.cell.ggml-small.languages").click()
        waitForElement(app.descendants(matching: .any)["popup.languages.local-whisper"])
        app.typeKey(.escape, modifierFlags: [])

        let english = element("models.cell.ggml-small.en.languages")
        waitForElement(english)
        XCTAssertEqual(english.elementType, .staticText, "An English-only model's cell is text, not a button")
    }

    /// T4-WO-02.
    func test_unloadMenuOffersSixOptions() {
        openLocalModels()
        let unload = waitForElement(element("models.whisper.unload"))
        unload.click()
        for title in ["30 seconds", "1 minute", "2 minutes", "5 minutes", "10 minutes", "Keep loaded"] {
            waitForElement(app.menuItems[title])
        }
        app.typeKey(.escape, modifierFlags: [])
        waitForElement(unload, toMatch: "value == '5 minutes'")
    }

    /// T4-WO-03 (04 Q8 default: a sheet).
    func test_editOpensThePromptSheet() {
        openLocalModels()
        waitForElement(element("models.whisper.prompt")).click()
        waitForElement(app.descendants(matching: .any)["models.whisper.promptEditor"])
    }
}
