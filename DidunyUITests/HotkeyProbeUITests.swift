import XCTest

/// T5-HK-00: XCUITest key events reach the Carbon global hotkeys that
/// KeyboardShortcuts registers. The WP-01 probe answered yes on CI for both
/// runs, so this now guards that answer; if it fails, the hotkey cases fall
/// back to the bridge (test-plan section 3.2).
///
/// Oracle: signed out, the Dictation hotkey (default ⌥⌘D) is refused by
/// `canStartRecording`, which opens the Account section of the main window.
/// Each run also records `T5-HK-00 <run> reached=<true|false>` as an activity,
/// a text attachment and a log line.
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

    /// Records the result, then fails if the hotkey did not reach the app.
    private func record(_ run: String, reached: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let result = "T5-HK-00 \(run) reached=\(reached)"
        XCTContext.runActivity(named: result) { activity in
            let attachment = XCTAttachment(string: result)
            attachment.name = "T5-HK-00 \(run)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print(result)
        XCTAssertTrue(
            reached,
            "T5-HK-00: XCUI key events no longer reach Carbon hotkeys; see test-plan §3.2 fallback",
            file: file,
            line: line
        )
    }

    func test_probeA_dictationHotkeyWithDidunyFrontmost_opensAccount() {
        launchSignedOutOnOverview()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.defaultTimeout), "Diduny is not frontmost")

        pressDictationHotkey(on: app)

        record("RunA", reached: oracleAppeared())
    }

    func test_probeB_dictationHotkeyWithTextEditFrontmost_opensAccount() {
        launchSignedOutOnOverview()
        let textEdit = XCUIApplication(bundleIdentifier: "com.apple.TextEdit")
        if textEdit.state == .notRunning {
            addTeardownBlock { textEdit.terminate() }
        }

        textEdit.activate()
        XCTAssertTrue(textEdit.wait(for: .runningForeground, timeout: Self.defaultTimeout), "TextEdit is not frontmost")

        pressDictationHotkey(on: textEdit)

        record("RunB", reached: oracleAppeared())
    }
}
