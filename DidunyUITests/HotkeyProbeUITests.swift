import XCTest

/// T5-HK-00 (WP-01 spike): do XCUITest key events reach the Carbon global
/// hotkeys that KeyboardShortcuts registers?
///
/// Oracle: signed out, the Dictation hotkey (default ⌥⌘D) is refused by
/// `canStartRecording`, which opens the Account section of the main window.
///
/// These are probes: each records `T5-HK-00 <run> reached=<true|false>` as an
/// activity, a text attachment and a log line, and passes either way. They fail
/// only when the probe itself cannot run (app not up, wrong starting section,
/// target app not frontmost).
final class HotkeyProbeUITests: DidunyUITestCase {
    private static let oracleTimeout: TimeInterval = 5

    private var mainWindow: XCUIElement { app.windows["Diduny"] }

    private func section(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)["section.\(id)"]
    }

    /// Signed-out app with the main window on Overview, so Account appears only
    /// if the hotkey reaches the app.
    private func launchSignedOutOnOverview() {
        launchApp(freshInstall: true, onboardingCompleted: true)
        waitForElement(section("overview"), "Main window did not open on Overview")
        XCTAssertFalse(section("account").exists, "Account must not show before the hotkey is sent")
    }

    private func pressDictationHotkey(on target: XCUIElement) {
        target.typeKey("d", modifierFlags: [.command, .option])
    }

    private func oracleAppeared() -> Bool {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: section("account"))
        return XCTWaiter().wait(for: [shown], timeout: Self.oracleTimeout) == .completed
    }

    private func record(_ run: String, reached: Bool) {
        let line = "T5-HK-00 \(run) reached=\(reached)"
        XCTContext.runActivity(named: line) { activity in
            let attachment = XCTAttachment(string: line)
            attachment.name = "T5-HK-00 \(run)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print(line)
    }

    func test_probeA_dictationHotkeyWithDidunyFrontmost_recordsWhetherAccountOpens() {
        launchSignedOutOnOverview()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.defaultTimeout), "Diduny is not frontmost")

        pressDictationHotkey(on: app)

        record("RunA", reached: oracleAppeared())
    }

    func test_probeB_dictationHotkeyWithTextEditFrontmost_recordsWhetherAccountOpens() {
        launchSignedOutOnOverview()
        let textEdit = XCUIApplication(bundleIdentifier: "com.apple.TextEdit")
        addTeardownBlock { textEdit.terminate() }

        textEdit.activate()
        XCTAssertTrue(textEdit.wait(for: .runningForeground, timeout: Self.defaultTimeout), "TextEdit is not frontmost")

        pressDictationHotkey(on: textEdit)

        record("RunB", reached: oracleAppeared())
    }
}
