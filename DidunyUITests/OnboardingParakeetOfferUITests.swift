import XCTest

/// WP-81: the Parakeet V3 card on the Ready screen (onboarding-parakeet.md). Opens Ready with
/// `--ui-testing-open=onboarding.ready`; the download is the Test build's fake, driven by the bridge. CI only.
final class OnboardingParakeetOfferUITests: DidunyUITestCase {
    private let id = "onboarding.modelOffer.parakeet-v3"

    private func element(_ suffix: String = "") -> XCUIElement {
        app.windows["Welcome to Diduny"].descendants(matching: .any)[suffix.isEmpty ? id : "\(id).\(suffix)"]
    }

    private func openReady(parakeet: String) {
        launchApp(open: "onboarding.ready", arguments: [
            "--ui-testing-fake-downloads", "--ui-testing-parakeet=\(parakeet)",
            "--ui-testing-input-bridge", "--ui-testing-probe",
        ])
        waitForElement(app.windows["Welcome to Diduny"].buttons["onboarding.primary"], toMatch: "label == 'Open Diduny'")
    }

    func test_hiddenWhenAlreadyDownloaded() {
        openReady(parakeet: "downloaded")
        XCTAssertFalse(element().exists)
    }

    func test_hiddenOnIntel() {
        openReady(parakeet: "unsupported")
        XCTAssertFalse(element().exists)
    }

    func test_downloadShowsPercentThenReady() {
        openReady(parakeet: "missing")
        waitForElement(element(), toMatch: "value == 'notDownloaded'")
        XCTAssertEqual(element("download").label, "Download 480 MB")
        element("download").click()
        waitForElement(element(), toMatch: "value == 'downloading'")
        bridge("download.advance", ["percent": 42])
        waitForElement(element("percent"), toMatch: "value == '42%' OR label == '42%'")
        bridge("download.advance", ["percent": 100])
        waitForElement(element(), toMatch: "value == 'ready'")
        waitForElement(element("ready"))
    }

    func test_cancelReturnsToNotDownloaded() {
        openReady(parakeet: "missing")
        waitForElement(element("download")).click()
        waitForElement(element("cancel")).click()
        waitForElement(element(), toMatch: "value == 'notDownloaded'")
    }

    func test_failureOffersRetryAndNotNowSkips() {
        openReady(parakeet: "missing")
        waitForElement(element("download")).click()
        waitForElement(element(), toMatch: "value == 'downloading'")
        bridge("download.fail")
        waitForElement(element(), toMatch: "value == 'failed'")
        waitForElement(element("failed"))
        element("retry").click()
        waitForElement(element(), toMatch: "value == 'downloading'")
        bridge("download.fail")
        waitForElement(element("notNow")).click()
        waitForElement(element(), toMatch: "value == 'skipped'")
        XCTAssertFalse(element("download").exists)
    }

    func test_openDidunyKeepsTheDownloadRunning() {
        openReady(parakeet: "missing")
        waitForElement(element("download")).click()
        waitForElement(element(), toMatch: "value == 'downloading'")
        app.windows["Welcome to Diduny"].buttons["onboarding.primary"].click()
        waitForDisappearance(app.windows["Welcome to Diduny"])
        bridge("download.advance", ["percent": 30])
        XCTAssertEqual((probe()["lastAction"] as? String), "download.advance")
    }
}
