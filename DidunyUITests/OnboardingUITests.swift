import XCTest

/// Setup guide on a fresh install. Steps past sign-in need the local backend
/// (OTP) and real system permissions, so they live in separate suites.
final class OnboardingUITests: DidunyUITestCase {
    private var onboardingWindow: XCUIElement { app.windows["Welcome to Diduny"] }
    private var heading: XCUIElement { onboardingWindow.staticTexts["onboarding.heading"] }
    private var primaryButton: XCUIElement { onboardingWindow.buttons["onboarding.primary"] }

    func test_freshInstallOpensWelcomeStep() {
        launchApp()

        waitForElement(onboardingWindow, "Setup guide window did not open on a fresh install")
        waitForElement(heading, toMatch: "label == 'Meet Diduny'")
        XCTAssertEqual(primaryButton.label, "Get started")
        XCTAssertTrue(primaryButton.isEnabled)
        XCTAssertTrue(onboardingWindow.buttons["onboarding.setUpLater"].exists)
        XCTAssertFalse(onboardingWindow.buttons["onboarding.back"].exists, "Welcome is the first step; Back must be hidden")
        XCTAssertEqual(onboardingWindow.descendants(matching: .any)["Onboarding progress"].value as? String, "Step 1 of 7")
    }

    func test_getStartedOpensSignInWithContinueBlockedUntilSignedIn() {
        launchApp()
        waitForElement(primaryButton).click()

        waitForElement(heading, toMatch: "label == 'Sign in'")
        waitForElement(onboardingWindow.textFields["account.email"])
        XCTAssertEqual(primaryButton.label, "Continue")
        XCTAssertFalse(primaryButton.isEnabled, "Continue must stay disabled until the user signs in")
        XCTAssertEqual(onboardingWindow.descendants(matching: .any)["Onboarding progress"].value as? String, "Step 2 of 7")
    }

    func test_backFromSignInReturnsToWelcome() {
        launchApp()
        waitForElement(primaryButton).click()
        waitForElement(heading, toMatch: "label == 'Sign in'")

        onboardingWindow.buttons["onboarding.back"].click()

        waitForElement(heading, toMatch: "label == 'Meet Diduny'")
        waitForDisappearance(onboardingWindow.buttons["onboarding.back"])
    }

    func test_sendCodeIsEnabledOnlyForAValidEmail() {
        launchApp()
        waitForElement(primaryButton).click()
        let email = waitForElement(onboardingWindow.textFields["account.email"])
        let sendCode = onboardingWindow.buttons["account.sendCode"]
        XCTAssertFalse(sendCode.isEnabled, "Empty email must not be sendable")

        email.click()
        email.typeText("not-an-email")
        waitForElement(sendCode, toMatch: "isEnabled == false")

        email.typeKey("a", modifierFlags: .command)
        email.typeText("tester@example.com")
        waitForElement(sendCode, toMatch: "isEnabled == true")
    }

    func test_sendCodeShowsErrorWhenServerIsUnreachable() {
        launchApp()
        waitForElement(primaryButton).click()
        let email = waitForElement(onboardingWindow.textFields["account.email"])
        email.click()
        email.typeText("tester@example.com")

        waitForElement(onboardingWindow.buttons["account.sendCode"], toMatch: "isEnabled == true")
        onboardingWindow.buttons["account.sendCode"].click()

        let error = waitForElement(onboardingWindow.staticTexts["account.error"])
        XCTAssertEqual(error.label, "Couldn't send a code. Try again.")
        XCTAssertFalse(onboardingWindow.textFields["account.otp"].exists, "Code entry must not appear when sending failed")
        XCTAssertFalse(primaryButton.isEnabled)
    }

    func test_setUpLaterClosesGuideAndOpensMainWindow() {
        launchApp()
        waitForElement(onboardingWindow.buttons["onboarding.setUpLater"]).click()

        waitForDisappearance(onboardingWindow)
        let mainWindow = waitForElement(app.windows["Diduny"], "Main window did not open after Set up later")
        waitForElement(mainWindow.buttons["Sidebar Overview"])
    }
}
