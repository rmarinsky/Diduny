import XCTest

/// Setup guide on a fresh install. Steps past sign-in need the local backend
/// (OTP) and real system permissions, so they live in separate suites.
final class OnboardingUITests: DidunyUITestCase {
    private var onboardingWindow: XCUIElement { app.windows["Welcome to Diduny"] }
    private var primaryButton: XCUIElement { onboardingWindow.buttons["onboarding.primary"] }
    private var progress: XCUIElement { onboardingWindow.descendants(matching: .any)["onboarding.progress"] }
    private var emailField: XCUIElement { onboardingWindow.textFields["account.email"] }

    private func heading(_ title: String) -> XCUIElement {
        text(title, identifier: "onboarding.heading", in: onboardingWindow)
    }

    /// Opens the Sign in step from Welcome and waits until Welcome is gone.
    private func openSignIn() {
        waitForElement(heading("Meet Diduny"))
        primaryButton.click()
        waitForElement(heading("Sign in"))
        waitForDisappearance(heading("Meet Diduny"))
    }

    func test_freshInstallOpensWelcomeStep() {
        launchApp()

        waitForElement(onboardingWindow, "Setup guide window did not open on a fresh install")
        waitForElement(heading("Meet Diduny"))
        XCTAssertEqual(primaryButton.label, "Get started")
        XCTAssertTrue(primaryButton.isEnabled)
        XCTAssertTrue(onboardingWindow.buttons["onboarding.setUpLater"].exists)
        XCTAssertFalse(onboardingWindow.buttons["onboarding.back"].exists, "Welcome is the first step; Back must be hidden")
        waitForElement(progress, toMatch: "value == 'Step 1 of 7'")
        XCTAssertFalse(app.windows["Diduny"].exists, "Main window must wait until setup is finished or skipped")
    }

    func test_getStartedOpensSignInWithContinueBlockedUntilSignedIn() {
        launchApp()
        openSignIn()

        waitForElement(emailField)
        XCTAssertEqual(primaryButton.label, "Continue")
        XCTAssertFalse(primaryButton.isEnabled, "Continue must stay disabled until the user signs in")
        XCTAssertTrue(onboardingWindow.buttons["onboarding.back"].exists)
        waitForElement(progress, toMatch: "value == 'Step 2 of 7'")
    }

    func test_backFromSignInReturnsToWelcome() {
        launchApp()
        openSignIn()

        onboardingWindow.buttons["onboarding.back"].click()

        waitForElement(heading("Meet Diduny"))
        waitForDisappearance(heading("Sign in"))
        waitForDisappearance(onboardingWindow.buttons["onboarding.back"])
        waitForElement(progress, toMatch: "value == 'Step 1 of 7'")
    }

    func test_sendCodeIsEnabledOnlyForAValidEmail() {
        launchApp()
        openSignIn()
        let email = waitForElement(emailField)
        let sendCode = onboardingWindow.buttons["account.sendCode"]
        XCTAssertFalse(sendCode.isEnabled, "Empty email must not be sendable")

        email.click()
        email.typeText("not-an-email")
        waitForElement(email, toMatch: "value == 'not-an-email'")
        XCTAssertFalse(sendCode.isEnabled, "An address without @ and domain must not be sendable")

        email.typeKey("a", modifierFlags: .command)
        email.typeText("tester@example.com")
        waitForElement(email, toMatch: "value == 'tester@example.com'")
        waitForElement(sendCode, toMatch: "isEnabled == true")
    }

    func test_sendCodeShowsErrorWhenServerIsUnreachable() {
        launchApp()
        openSignIn()
        let email = waitForElement(emailField)
        email.click()
        email.typeText("tester@example.com")
        waitForElement(email, toMatch: "value == 'tester@example.com'")
        let sendCode = onboardingWindow.buttons["account.sendCode"]
        waitForElement(sendCode, toMatch: "isEnabled == true")

        sendCode.click()

        waitForElement(text("Couldn't send a code. Try again.", identifier: "account.error", in: onboardingWindow))
        waitForElement(sendCode, toMatch: "isEnabled == true")
        XCTAssertFalse(onboardingWindow.textFields["account.otp"].exists, "Code entry must not appear when sending failed")
        XCTAssertFalse(primaryButton.isEnabled, "Continue must stay disabled after a failed sign-in")
    }

    func test_setUpLaterClosesGuideAndOpensMainWindow() {
        launchApp()
        waitForElement(onboardingWindow.buttons["onboarding.setUpLater"]).click()

        waitForDisappearance(onboardingWindow)
        let mainWindow = waitForElement(app.windows["Diduny"], "Main window did not open after Set up later")
        waitForElement(mainWindow.descendants(matching: .any)["section.overview"])
        waitForElement(mainWindow.buttons["Sidebar Overview"], toMatch: "value == 'Selected'")
    }
}
