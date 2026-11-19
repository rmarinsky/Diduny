import AppKit
import XCTest
@testable import PapugaKit

@MainActor
final class TypingEngineTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypingEngineTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Typing", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func makeEngine(settings: TypingSettings = TypingSettings()) -> TypingEngine {
        TypingEngine(storageDirectory: directory, settings: { settings }, logSubsystem: "papugakit.tests")
    }

    func test_constructionCreatesTheDirectoryAndDoesNotStart() {
        let engine = makeEngine()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(engine.isRunning)
    }

    func test_filesLandInTheGivenDirectory() throws {
        let engine = makeEngine()

        engine.replacementHistory.record(ReplacementHistoryEntry(kind: .autoFixApplied, original: "ghbdsn", converted: "привіт"))
        engine.eventLog.track(AnalyticsEvent(kind: AnalyticsKind.autoFixApplied))

        let expected = ["replacement-history.jsonl", "events.jsonl"]
        let deadline = Date().addingTimeInterval(5)
        var names: [String] = []
        while Date() < deadline {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if expected.allSatisfy(names.contains) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        for name in expected {
            XCTAssertTrue(names.contains(name), "\(name) missing; found \(names)")
        }
    }

    func test_historySettingsReachBothStores() {
        var settings = TypingSettings()
        settings.replacementHistoryEnabled = false
        settings.replacementHistoryRetention = ReplacementHistoryRetention.oneWeek.rawValue
        let engine = makeEngine(settings: settings)

        XCTAssertFalse(engine.replacementHistory.isEnabled)
        XCTAssertEqual(engine.replacementHistory.retention, .oneWeek)
        XCTAssertFalse(engine.decisionHistory.isEnabled)
        XCTAssertEqual(engine.decisionHistory.retention, .oneWeek)
    }

    /// Whether the tap can be created depends on the permissions of the process that runs the
    /// tests, so only the contract is checked: the result matches `isRunning`, and `stop()` is
    /// safe after either result and safe twice.
    func test_startReportsItsResultAndStopIsSafeTwice() {
        let engine = makeEngine()

        let started = engine.start()
        XCTAssertEqual(engine.isRunning, started)

        engine.stop()
        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }

    /// Overview's "Layout fixes" card counts manual conversions (Convert) as well as automatic fixes.
    func test_convertIsRecordedAsAFix() {
        var recorded: [String] = []
        let engine = TypingEngine(
            storageDirectory: directory,
            settings: { TypingSettings() },
            logSubsystem: "papugakit.tests",
            onReplacementRecorded: { recorded.append($0) }
        )

        engine.finishLayoutConversion(TypingLayoutConversion(
            original: "ghbdsn", converted: "привіт", sourceLayoutID: "test.none", targetLayoutID: "test.none"
        ))

        XCTAssertEqual(recorded, ["ghbdsn"])
    }

    /// Convert shows the swap hint, never the fix hint with its undo click.
    func test_convertShowsTheSwapHintUnlessHintsAreOff() {
        for enabled in [true, false] {
            let hints = FixToastCounter()
            var settings = TypingSettings()
            settings.autoFixToastEnabled = enabled
            let engine = TypingEngine(
                storageDirectory: directory, settings: { settings }, logSubsystem: "papugakit.tests", hintPresenter: hints
            )

            engine.finishLayoutConversion(TypingLayoutConversion(
                original: "ghbdsn", converted: "привіт", sourceLayoutID: "test.none", targetLayoutID: "test.none"
            ))

            XCTAssertEqual(hints.swaps, enabled ? 1 : 0)
            XCTAssertEqual(hints.clickable, [])
        }
    }

    func test_stopWritesTheCadenceOnlyAfterAStart() {
        var gaps: [Double] = []
        let engine = TypingEngine(
            storageDirectory: directory,
            settings: { TypingSettings() },
            logSubsystem: "papugakit.tests",
            onCadenceGapWritten: { gaps.append($0) }
        )

        engine.stop()
        XCTAssertTrue(gaps.isEmpty)

        if engine.start() {
            engine.stop()
            engine.stop()
            XCTAssertEqual(gaps.count, 1)
        }
    }
}

@MainActor
private final class FixToastCounter: TypingHintPresenting {
    var clickable: [Bool] = []
    var swaps = 0

    func showFixToast(near _: NSPoint, onClick: (() -> Void)?) { clickable.append(onClick != nil) }
    func showSwapHint(near _: NSPoint) { swaps += 1 }
    func showRecovery(_: TypingRecoveryHint, near _: NSPoint, onClick _: @escaping () -> Void) {}
    func showDeferredChip(
        original _: String, candidate _: String, near _: NSPoint, timeToLive _: TimeInterval,
        onApply _: @escaping () -> Void, onDismiss _: @escaping () -> Void, onExpire _: @escaping () -> Void
    ) {}
    func dismissChip() {}
    func dismissFixToast() {}
    func isMouseOverToast() -> Bool { false }
    func isMouseOverChip() -> Bool { false }
    func showProposal(_: TypingProposalHint, near _: NSPoint, duration _: TimeInterval, actions _: TypingProposalActions) {}
    func dismissProposal(outcome _: TypingProposalOutcome?) {}
    func handleProposalKeyboardShortcut(keyCode _: UInt16, flags _: CGEventFlags) -> Bool { false }
    func isMouseOverProposal() -> Bool { false }
}
