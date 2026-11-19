import XCTest
@testable import PapugaKit

final class ManualCorrectionTrackerTests: XCTestCase {
    func test_detectsDeleteAndRetypeCorrection() {
        let tracker = ManualCorrectionTracker(correctionWindow: 10, minDeleteCount: 2, minWordLength: 3)

        XCTAssertNil(tracker.noteCompletedWord(
            "pomylkka",
            language: "uk",
            bundleID: "com.example.editor",
            timestamp: 1
        ))
        tracker.noteBackspace(bufferWasEmpty: true, timestamp: 2)
        tracker.noteBackspace(bufferWasEmpty: true, timestamp: 2.2)

        let candidate = tracker.noteCompletedWord(
            "pomylka",
            language: "uk",
            bundleID: "com.example.editor",
            timestamp: 4
        )

        XCTAssertEqual(candidate?.source, "pomylkka")
        XCTAssertEqual(candidate?.target, "pomylka")
        XCTAssertEqual(candidate?.language, "uk")
        XCTAssertEqual(candidate?.bundleID, "com.example.editor")
        XCTAssertGreaterThan(candidate?.confidence ?? 0, 0.6)
    }

    func test_doesNotInferWhenBackspaceWasInsideCurrentBuffer() {
        let tracker = ManualCorrectionTracker(correctionWindow: 10, minDeleteCount: 2, minWordLength: 3)

        _ = tracker.noteCompletedWord("pomylkka", language: "uk", bundleID: nil, timestamp: 1)
        tracker.noteBackspace(bufferWasEmpty: false, timestamp: 2)
        tracker.noteBackspace(bufferWasEmpty: false, timestamp: 2.2)

        let candidate = tracker.noteCompletedWord("pomylka", language: "uk", bundleID: nil, timestamp: 4)

        XCTAssertNil(candidate)
    }

    func test_rejectsUnrelatedReplacement() {
        let tracker = ManualCorrectionTracker(correctionWindow: 10, minDeleteCount: 2, minWordLength: 3)

        _ = tracker.noteCompletedWord("pomylkka", language: "uk", bundleID: nil, timestamp: 1)
        tracker.noteBackspace(bufferWasEmpty: true, timestamp: 2)
        tracker.noteBackspace(bufferWasEmpty: true, timestamp: 2.2)

        let candidate = tracker.noteCompletedWord("calendar", language: "uk", bundleID: nil, timestamp: 4)

        XCTAssertNil(candidate)
    }

    func test_expiresCorrectionWindow() {
        let tracker = ManualCorrectionTracker(correctionWindow: 3, minDeleteCount: 2, minWordLength: 3)

        _ = tracker.noteCompletedWord("pomylkka", language: "uk", bundleID: nil, timestamp: 1)
        tracker.noteBackspace(bufferWasEmpty: true, timestamp: 2)
        tracker.noteBackspace(bufferWasEmpty: true, timestamp: 2.2)

        let candidate = tracker.noteCompletedWord("pomylka", language: "uk", bundleID: nil, timestamp: 8)

        XCTAssertNil(candidate)
    }

    func test_chipMatchesOnlyWholeTokens() {
        XCTAssertTrue(ManualCorrectionTracker.phrase("nj ljhtxs", containsToken: "ljhtxs"))
        XCTAssertTrue(ManualCorrectionTracker.phrase("nj ljhtxs,", containsToken: "LJHTXS"))
        XCTAssertFalse(ManualCorrectionTracker.phrase("other words", containsToken: "the"),
                       "a correction of 'the' must not drop a chip for 'other'")
    }
}
