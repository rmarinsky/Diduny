import XCTest

/// Command home (WP-41). Runs on CI only (`DIDUNY_UI_TESTS=1`).
final class CommandPanelUITests: DidunyUITestCase {
    /// Hovers the collapsed tab (the real path, T2-HM-01) and returns the home. `P-STD` pins the tab,
    /// which otherwise hides itself after 3 s.
    /// The panel window is not exposed as an XCUI window, so the tab (`commandPanel.tab`) stands for it.
    private func openHome() -> (tab: XCUIElement, home: XCUIElement) {
        let app = launchApp(onboardingCompleted: true, profile: .standard)
        let tab = waitForElement(app.descendants(matching: .any)["commandPanel.tab"])
        waitForElement(tab, toMatch: "isHittable == true")
        tab.hover()
        let home = waitForElement(app.descendants(matching: .any)["commandPanel.home"])
        return (tab, home)
    }

    /// WP-20 carry-over: a pick made with the pointer outside the panel collapses it once the menu closes.
    func testPickingFromTheEngineMenuOutsideThePanelCollapsesIt() throws {
        let (tab, home) = openHome()
        let panelFrame = home.frame
        home.buttons["commandPanel.engine"].click()

        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pickerMenu.row.' AND isEnabled == true"))
        waitForElement(rows.firstMatch)
        let outside = rows.allElementsBoundByIndex.first { row in
            let id = row.identifier
            return !id.hasSuffix(".providers") && !panelFrame.contains(CGPoint(x: row.frame.midX, y: row.frame.midY))
        }
        let row = try XCTUnwrap(outside, "No engine row lies outside the panel")
        row.click()

        waitForDisappearance(home)
        waitForElement(tab, "The collapsed tab stays on screen")
    }

    func testHomeShowsEngineAndTranslateIntoAndAllTiles() {
        let (_, home) = openHome()

        waitForElement(home.buttons["commandPanel.engine"], toMatch: "value == 'As in Settings'")
        waitForElement(home.buttons["commandPanel.translateInto"])
        for tile in ["transcribe", "translate", "recordMeeting", "translateMeeting"] {
            waitForElement(home.buttons["commandPanel.tile.\(tile)"])
        }
        waitForElement(home.buttons["commandPanel.recordings"])
        waitForElement(home.buttons["commandPanel.settings"])
        waitForElement(home.buttons["commandPanel.batch"])
        XCTAssertFalse(home.staticTexts["What do you want to capture?"].exists)
    }

    func testCloseCollapsesToTheTab() {
        let (tab, home) = openHome()

        home.buttons["commandPanel.close"].click()

        waitForDisappearance(home)
        waitForElement(tab)
    }
}
