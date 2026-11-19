import Carbon.HIToolbox
import XCTest
@testable import PapugaKit

/// The seams added when the controller moved into the package: live settings, the settings
/// writer, the undo-shortcut provider and the two host controls.
@MainActor
final class AutoFixControllerSeamTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_settingsProviderIsReadLive() throws {
        let file = directory.appendingPathComponent("decisions.jsonl")
        let store = AutoFixDecisionHistoryStore(testFileURL: file)
        let harness = AutoFixControllerHarness(directory: directory, decisionHistory: store)

        harness.controller.recordProposalPresentation(makeProposal())
        harness.settings.autoFixProposalWindow = 0.31
        harness.settings.autoFixCandidateSeparation = 0.27
        harness.settings.autoFixMinWordLength = 5
        harness.controller.recordProposalPresentation(makeProposal())
        store.waitForPendingWritesForTesting()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observations = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(AutoFixDecisionObservation.self, from: Data($0.utf8)) }
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations[0].proposalWindow, 0.22)
        XCTAssertEqual(observations[0].candidateSeparation, 0.15)
        XCTAssertEqual(observations[0].minimumWordLength, 2)
        XCTAssertEqual(observations[1].proposalWindow, 0.31)
        XCTAssertEqual(observations[1].candidateSeparation, 0.27)
        XCTAssertEqual(observations[1].minimumWordLength, 5)
    }

    func test_secureFieldIsNeverBufferedFixedOrRecorded() {
        let harness = AutoFixControllerHarness(directory: directory)
        harness.isSecureField = true
        let controller = harness.controller
        // "ghbdsn" is "привіт" typed in the wrong layout: a fix candidate in a normal field.
        for (code, char) in [(kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_B, "b"),
                             (kVK_ANSI_D, "d"), (kVK_ANSI_S, "s"), (kVK_ANSI_N, "n")] {
            controller.processKeyDownForTesting(keyCode: UInt16(code), typedString: char)
        }
        XCTAssertEqual(controller.typingBufferForTesting, "")
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_Space), typedString: " ")

        XCTAssertFalse(controller.hasPendingUndoForTesting)
        XCTAssertTrue(harness.stats.recorded.isEmpty)
        XCTAssertTrue(ReplacementHistoryStore(directory: directory).loadEntriesSync().isEmpty)
    }

    func test_secureFocusAtTheBoundaryDropsTheBufferedWord() {
        let harness = AutoFixControllerHarness(directory: directory)
        let controller = harness.controller
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_G), typedString: "g")
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_H), typedString: "h")
        harness.isSecureField = true
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_Space), typedString: " ")

        XCTAssertEqual(controller.typingBufferForTesting, "")
        XCTAssertFalse(controller.hasPendingUndoForTesting)
        XCTAssertTrue(harness.stats.recorded.isEmpty)
        XCTAssertTrue(ReplacementHistoryStore(directory: directory).loadEntriesSync().isEmpty)
    }

    func test_noteExternalEditClearsTheTypingBuffer() {
        let harness = AutoFixControllerHarness(directory: directory)
        let controller = harness.controller
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_G), typedString: "g")
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_H), typedString: "h")
        XCTAssertEqual(controller.typingBufferForTesting, "gh")
        let toastDismissals = harness.presenter.toastDismissals
        let proposalDismissals = harness.presenter.proposalDismissals.count

        controller.noteExternalEdit()

        XCTAssertEqual(controller.typingBufferForTesting, "")
        XCTAssertFalse(controller.hasPendingUndoForTesting)
        XCTAssertEqual(harness.presenter.toastDismissals, toastDismissals + 1)
        XCTAssertEqual(harness.presenter.proposalDismissals.count, proposalDismissals + 1)
        XCTAssertEqual(harness.presenter.proposalDismissals.last, .some(nil))

        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_B), typedString: "b")
        XCTAssertEqual(controller.typingBufferForTesting, "b", "typing after the host edit starts a new word")
    }

    func test_pauseAndResumeBothDropTheTypingBuffer() {
        let controller = AutoFixControllerHarness(directory: directory).controller
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_G), typedString: "g")
        XCTAssertFalse(controller.isPaused)

        controller.setPaused(true)
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.typingBufferForTesting, "")

        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_H), typedString: "h")
        controller.setPaused(false)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(controller.typingBufferForTesting, "")
    }

    func test_undoShortcutProviderIsReadLive() {
        let harness = AutoFixControllerHarness(directory: directory)
        let controller = harness.controller
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_G), typedString: "g")

        // Not the undo shortcut yet: a Command chord resets the typing state.
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_Z), typedString: "z", flags: .maskCommand)
        XCTAssertEqual(controller.typingBufferForTesting, "")

        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_G), typedString: "g")
        harness.undoShortcut = AutoFixUndoShortcut(carbonKeyCode: kVK_ANSI_Z, modifiers: .command)
        controller.processKeyDownForTesting(keyCode: UInt16(kVK_ANSI_Z), typedString: "z", flags: .maskCommand)
        XCTAssertEqual(controller.typingBufferForTesting, "g", "the undo shortcut must not reset the typing state")
    }

    func test_stopWritesTheCadenceGapThroughTheWriter() {
        var settings = TypingSettings()
        settings.typingCadenceAverageGap = 0.21
        let harness = AutoFixControllerHarness(directory: directory, settings: settings)
        XCTAssertEqual(harness.writer.cadenceGaps, [])

        harness.controller.stop()

        XCTAssertEqual(harness.writer.cadenceGaps, [0.21], "the gap restored at init is the gap persisted on stop")
    }

    func test_startReportsWhetherTheTapIsLive() {
        let tap = AutoFixEventTap(mask: CGEventMask(1 << CGEventType.keyDown.rawValue))
        var marker = 0
        let started = withUnsafeMutablePointer(to: &marker) { pointer in
            tap.start(userInfo: UnsafeMutableRawPointer(pointer)) { _, _, event, _ in
                Unmanaged.passUnretained(event)
            }
        }
        // Whether a tap can be created depends on the Accessibility permission of the test host.
        // Either way the answer must match the tap's real state.
        XCTAssertEqual(started, tap.isActive)
        tap.stop()
    }

    private func makeProposal() -> AutoFixProposal {
        AutoFixProposal(
            original: "ghbds",
            candidate: "привіт",
            boundary: " ",
            fromLayoutID: "en",
            targetLayoutID: "uk",
            scoreOriginal: 0.1,
            scoreCandidate: 0.4,
            threshold: 0.35,
            algorithm: .appleNL,
            currentLang: "en",
            targetLang: "uk",
            bundleID: "com.example.app",
            createdAt: 0,
            replacementAnchor: TextReplacementAnchor(
                targetPID: 10,
                bundleID: "com.example.app",
                focusedElementIdentity: FocusedElementSignature.StableIdentity(
                    pid: 10,
                    role: "AXTextArea",
                    subrole: nil,
                    windowTitleHash: nil,
                    elementIdentifier: nil,
                    frameHash: nil
                ),
                sourceRange: AXTextRange(location: 0, length: 5),
                boundaryUTF16Length: 1,
                caretAfterBoundary: 6,
                expectedSource: "ghbds",
                allowsKeyboardFallback: false
            ),
            kind: .detected
        )
    }
}
