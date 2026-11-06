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
        // T5-SB-02: sidebar label → section id and an element only that section shows.
        let sections: [(label: String, id: String, marker: (XCUIElement) -> XCUIElement)] = [
            ("General", "general", { $0.staticTexts["After a recording"] }),
            ("Modes", "modes", { $0.staticTexts["Use one engine for everything"] }),
            ("Languages", "languages", { $0.staticTexts["Your languages"] }),
            ("Audio", "audioDictation", { $0.staticTexts["Test the microphone"] }),
            ("Calendar & meetings", "meetings", { $0.staticTexts["Calendars"] }),
            ("Local models", "models", { $0.staticTexts["Whisper options"] }),
            ("Providers", "providers", { $0.staticTexts["In Diduny"] }),
            ("Shortcuts", "shortcuts", { $0.staticTexts["While recording"] }),
            ("About", "about", { $0.staticTexts["Author"] }),
            ("Account", "account", { $0.textFields["account.email"] }),
            ("About", "about", { $0.staticTexts["Author"] }),
            ("Benchmark", "benchmark", { $0.staticTexts["Benchmark"] }),
            ("Typing test", "typingTest", { $0.staticTexts["Typing Speed Test"] }),
            ("Recordings", "recordings", { $0.staticTexts["No Recordings Yet"] }),
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

    /// T5-SB-03 (value part). The click-to-dictate part needs the P-STD harness
    /// (stub engines, probe); it is added once that harness lands.
    func test_sidebarStartRecordingShowsTheDictationShortcut() {
        launchApp(onboardingCompleted: true)
        let start = waitForElement(mainWindow.buttons["Start Recording"])
        waitForElement(start, toMatch: "value == '⌥⌘D'")
    }

    /// T5-HK-16
    func test_commandCommaOpensGeneralSettings() {
        launchApp(onboardingCompleted: true)
        waitForElement(section("overview"))
        mainWindow.typeKey(",", modifierFlags: .command)
        waitForElement(section("general"), "⌘, did not open Settings > General")
    }

    /// T5-HK-15. No `batchComposer` identifier exists yet, so this checks that
    /// ⇧⌘B lands on Recordings, where the composer opens.
    func test_shiftCommandBOpensFilesAndURLs() {
        launchApp(onboardingCompleted: true)
        waitForElement(section("overview"))
        mainWindow.typeKey("b", modifierFlags: [.command, .shift])
        waitForElement(section("recordings"), "⇧⌘B did not open Files and URLs")
    }

    /// T5-HK-43 (menu bar access unverified, test-plan 2.6).
    func test_menuBarItemsAreReachable() {
        launchApp(onboardingCompleted: true)
        app.statusItems.firstMatch.click()
        for title in ["Dictation", "Translation", "Meeting", "Meeting Translation"] {
            waitForElement(app.menuItems.containing(NSPredicate(format: "title CONTAINS %@", title)).firstMatch,
                           "Menu bar item \(title) is missing")
        }
    }
}
