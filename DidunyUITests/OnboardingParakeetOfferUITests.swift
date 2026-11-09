import XCTest

/// WP-81: the Parakeet V3 card on the Ready screen (onboarding-parakeet.md). Opens Ready with
/// `--ui-testing-open=onboarding.ready`; the download is the Test build's fake, driven by the bridge. CI only.
final class OnboardingParakeetOfferUITests: DidunyUITestCase {
    private let id = "onboarding.modelOffer.parakeet-v3"
    // macOS does not expose the card group's accessibility value to XCUI, so each state is proven
    // by the control only that state shows (download, cancel, retry, ready, the skipped line).

    private func element(_ suffix: String = "") -> XCUIElement {
        app.windows["Welcome to Diduny"].descendants(matching: .any)[suffix.isEmpty ? id : "\(id).\(suffix)"]
    }

    /// A sibling of the card on Ready; the subtitle is unique to the badge.
    private var doubleOptionBadge: XCUIElement {
        app.windows["Welcome to Diduny"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Translate automatically' OR value CONTAINS 'Translate automatically'")).firstMatch
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
        waitForElement(doubleOptionBadge)
        XCTAssertFalse(element().exists)
    }

    func test_hiddenOnIntel() {
        openReady(parakeet: "unsupported")
        waitForElement(doubleOptionBadge)
        XCTAssertFalse(element().exists)
    }

    func test_downloadShowsPercentThenReady() {
        openReady(parakeet: "missing")
        waitForElement(element("download"))
        XCTAssertEqual(element("download").label, "Download 480 MB")
        element("download").click()
        waitForElement(element("cancel"))
        bridge("download.advance", ["percent": 42])
        waitForElement(element("percent"), toMatch: "value == '42%' OR label == '42%'")
        bridge("download.advance", ["percent": 100])
        waitForElement(element("ready"))
        waitForElement(element("title"), toMatch: "value == 'Parakeet V3 is ready' OR label == 'Parakeet V3 is ready'")
    }

    func test_cancelReturnsToNotDownloaded() {
        openReady(parakeet: "missing")
        waitForElement(element("download")).click()
        waitForElement(element("cancel")).click()
        waitForElement(element("download"))
    }

    func test_failureOffersRetryAndNotNowSkips() {
        openReady(parakeet: "missing")
        waitForElement(element("download")).click()
        waitForElement(element("cancel"))
        bridge("download.fail")
        waitForElement(element("retry"))
        waitForElement(element("failed"))
        element("retry").click()
        waitForElement(element("cancel"))
        bridge("download.fail")
        waitForElement(element("notNow")).click()
        waitForElement(element(), toMatch: "label CONTAINS 'whenever you want it'")
        XCTAssertFalse(element("download").exists)
    }

    func test_openDidunyKeepsTheDownloadRunning() {
        openReady(parakeet: "missing")
        waitForElement(element("download")).click()
        waitForElement(element("cancel"))
        app.windows["Welcome to Diduny"].buttons["onboarding.primary"].click()
        waitForDisappearance(app.windows["Welcome to Diduny"])
        bridge("download.advance", ["percent": 30])
        var parakeet = probe()["parakeet"] as? [String: Any]
        XCTAssertEqual(parakeet?["state"] as? String, "downloading")
        XCTAssertEqual(parakeet?["percent"] as? Int, 30)

        bridge("download.advance", ["percent": 100])
        waitForElement(probeElement, toMatch: "value CONTAINS '\"state\":\"downloaded\"'")
        parakeet = probe()["parakeet"] as? [String: Any]
        XCTAssertEqual(parakeet?["state"] as? String, "downloaded")
    }
}
