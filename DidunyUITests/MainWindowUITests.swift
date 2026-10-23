import XCTest

/// Main window navigation once setup is complete.
final class MainWindowUITests: DidunyUITestCase {
    private var mainWindow: XCUIElement { app.windows["Diduny"] }

    private func section(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)["section.\(id)"]
    }

    func test_completedSetupOpensMainWindowOnOverview() {
        launchApp(onboardingCompleted: true)

        waitForElement(mainWindow, "Main window did not open when setup is complete")
        let overview = waitForElement(section("overview"))
        waitForElement(overview.staticTexts["Overview"])
        waitForElement(mainWindow.buttons["Sidebar Overview"], toMatch: "value == 'Selected'")
        XCTAssertFalse(app.windows["Welcome to Diduny"].exists, "Setup guide must not open once setup is complete")
    }

    func test_everySidebarItemShowsItsSection() {
        launchApp(onboardingCompleted: true)
        waitForElement(section("overview"))

        // Sidebar label → section id and an element only that section shows.
        let sections: [(label: String, id: String, marker: (XCUIElement) -> XCUIElement)] = [
            ("Recordings", "recordings", { $0.staticTexts["No Recordings Yet"] }),
            ("Typing Test", "typingTest", { $0.staticTexts["Typing Speed Test"] }),
            ("General", "general", { $0.staticTexts["Behavior"] }),
            ("Audio & Dictation", "audioDictation", { $0.staticTexts["Test Recording"] }),
            ("Calendar & Meetings", "meetings", { $0.staticTexts["Calendars"] }),
            ("Models", "models", { $0.staticTexts["Whisper Models"] }),
            ("Shortcuts", "shortcuts", { $0.staticTexts["Editable"] }),
            ("Account", "account", { $0.textFields["account.email"] }),
            ("Overview", "overview", { $0.staticTexts["Overview"] }),
        ]

        var previous = (label: "Overview", id: "overview")
        for entry in sections {
            let item = waitForElement(mainWindow.buttons["Sidebar \(entry.label)"])
            item.click()

            let container = waitForElement(section(entry.id), "\(entry.label) did not show its section")
            waitForElement(entry.marker(container), "\(entry.label) is missing its content")
            waitForElement(item, toMatch: "value == 'Selected'")
            if previous.id != entry.id {
                waitForDisappearance(section(previous.id))
                waitForElement(mainWindow.buttons["Sidebar \(previous.label)"], toMatch: "value != 'Selected'")
            }
            previous = (entry.label, entry.id)
        }
    }
}
