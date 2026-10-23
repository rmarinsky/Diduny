import XCTest

/// Base for Diduny UI tests: launches the app in a known state, waits for
/// expected UI instead of sleeping, and attaches a screenshot of every test.
class DidunyUITestCase: XCTestCase {
    /// Nothing listens here, so cloud calls fail fast instead of reaching production.
    static let unreachableProxyURL = "http://127.0.0.1:9"
    static let defaultTimeout: TimeInterval = 15

    private(set) var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "\(name) - final state"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    /// - Parameters:
    ///   - freshInstall: wipes this build's settings, sign-in and library first.
    ///   - onboardingCompleted: skips the setup guide so the main window opens.
    @discardableResult
    func launchApp(
        freshInstall: Bool = true,
        onboardingCompleted: Bool = false,
        proxyURL: String = DidunyUITestCase.unreachableProxyURL,
        appearance: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-proxyBaseURL", proxyURL,
            // An update alert would cover windows and take focus.
            "-SUEnableAutomaticChecks", "NO",
        ]
        if freshInstall {
            app.launchArguments.append("--ui-testing-reset")
        }
        if onboardingCompleted {
            app.launchArguments += ["-onboarding.completed", "YES", "-onboarding.version", "1"]
        }
        if let appearance {
            app.launchArguments += ["-AppleInterfaceStyle", appearance]
        }
        app.launch()
        self.app = app
        return app
    }

    /// Fails the test unless `element` appears within `timeout`.
    @discardableResult
    func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval = DidunyUITestCase.defaultTimeout,
        _ message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            message ?? "Timed out waiting for \(element)",
            file: file,
            line: line
        )
        return element
    }

    /// Fails the test unless `predicate` holds for `element` within `timeout`,
    /// e.g. `"isEnabled == false"` or `"label == 'Sign in'"`.
    func waitForElement(
        _ element: XCUIElement,
        toMatch predicate: String,
        timeout: TimeInterval = DidunyUITestCase.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed else { return }
        // Read attributes only when the element is there; a missing element would raise a second error.
        let state = element.exists ? "label=\(element.label), value=\(String(describing: element.value))" : "element missing"
        XCTFail("\(element) never matched \(predicate); \(state)", file: file, line: line)
    }

    /// Fails the test unless `element` disappears within `timeout`.
    func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval = DidunyUITestCase.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForElement(element, toMatch: "exists == false", timeout: timeout, file: file, line: line)
    }

    /// The static text with `identifier` showing `text`. SwiftUI on macOS exposes
    /// a Text's string as the element's value, not its label.
    func text(_ text: String, identifier: String, in container: XCUIElement) -> XCUIElement {
        container.staticTexts
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", identifier, text))
            .firstMatch
    }
}
