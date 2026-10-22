import XCTest

/// Main window navigation once setup is complete.
final class MainWindowUITests: DidunyUITestCase {
    private var mainWindow: XCUIElement { app.windows["Diduny"] }

    func test_completedSetupOpensMainWindowOnOverview() {
        launchApp(onboardingCompleted: true)

        waitForElement(mainWindow, "Main window did not open when setup is complete")
        XCTAssertFalse(app.windows["Welcome to Diduny"].exists, "Setup guide must not open once setup is complete")
        waitForElement(mainWindow.descendants(matching: .any)["section.overview"])
        XCTAssertEqual(mainWindow.buttons["Sidebar Overview"].value as? String, "Selected")
    }

    func test_everySidebarItemShowsItsSection() {
        launchApp(onboardingCompleted: true)
        waitForElement(mainWindow)

        // Sidebar label → section id and a text only that section shows.
        let sections: [(label: String, id: String, expectedText: String?)] = [
            ("Recordings", "recordings", "No Recordings Yet"),
            ("Typing Test", "typingTest", "Typing Speed Test"),
            ("General", "general", "Behavior"),
            ("Audio & Dictation", "audioDictation", "Test Recording"),
            ("Calendar & Meetings", "meetings", "Meeting Suggestions"),
            ("Models", "models", nil),
            ("Shortcuts", "shortcuts", "Editable"),
            ("Account", "account", nil),
            ("Overview", "overview", nil),
        ]

        for section in sections {
            let item = waitForElement(mainWindow.buttons["Sidebar \(section.label)"])
            item.click()

            let container = waitForElement(
                mainWindow.descendants(matching: .any)["section.\(section.id)"],
                "\(section.label) did not show its section"
            )
            waitForElement(item, toMatch: "value == 'Selected'")
            if let expectedText = section.expectedText {
                waitForElement(container.staticTexts[expectedText], "\(section.label) is missing '\(expectedText)'")
            } else {
                XCTAssertGreaterThan(container.staticTexts.count, 0, "\(section.label) shows no text")
            }
        }
    }
}
