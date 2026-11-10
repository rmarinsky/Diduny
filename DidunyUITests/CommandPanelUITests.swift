import XCTest

/// Command home (WP-41). Runs on CI only (`DIDUNY_UI_TESTS=1`).
final class CommandPanelUITests: DidunyUITestCase {
    /// Opens the home with `--ui-testing-open=commandPanel.home` (test-plan 2.6; the hover path is
    /// T2-HM-01's). `P-STD` pins the panel. The tab stands for the panel, which XCUI does not list
    /// as a window.
    private func openHome() -> (tab: XCUIElement, home: XCUIElement) {
        let app = launchApp(onboardingCompleted: true, profile: .standard, open: "commandPanel.home")
        let home = waitForElement(app.descendants(matching: .any)["commandPanel.home"])
        return (app.descendants(matching: .any)["commandPanel.tab"], home)
    }

    /// Roman, 2026-11-09: an Engine pick made with the pointer outside the panel returns the pointer to
    /// the Engine field, so the panel stays open once the menu closes. This replaces the WP-20 carry-over,
    /// where the panel collapsed.
    func testPickingFromTheEngineMenuOutsideThePanelKeepsItOpen() throws {
        let (_, home) = openHome()
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

        waitForDisappearance(row)
        XCTAssertFalse(home.waitForNonExistence(timeout: 2), "The panel collapsed after the pick")
    }

    func testHomeShowsEngineAndTranslateIntoAndAllTiles() {
        let (_, home) = openHome()

        waitForElement(home.buttons["commandPanel.engine"], toMatch: "value == 'Diduny Cloud'")
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
