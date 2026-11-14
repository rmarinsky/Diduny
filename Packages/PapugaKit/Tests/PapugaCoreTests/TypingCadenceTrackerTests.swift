import XCTest
@testable import PapugaCore

final class TypingCadenceTrackerTests: XCTestCase {
    func test_seedFromMeasuredWPMUsesFiveCharWords() {
        // 100 WPM = 500 chars/min = 0.12 s per keystroke.
        XCTAssertEqual(TypingCadenceTracker.seededGap(wordsPerMinute: 100), 0.12, accuracy: 0.0001)
        XCTAssertEqual(
            TypingCadenceTracker.seededGap(wordsPerMinute: 0),
            TypingCadenceTracker.defaultGap
        )
    }

    func test_averageConvergesTowardTheTypistsRealGap() {
        var tracker = TypingCadenceTracker()
        var now: TimeInterval = 0
        for _ in 0..<200 {
            tracker.notePrintable(at: now)
            now += 0.08
        }
        XCTAssertEqual(tracker.averageGap, 0.08, accuracy: 0.01)
    }

    func test_pausesDoNotDragTheAverage() {
        var tracker = TypingCadenceTracker(averageGap: 0.1)
        tracker.notePrintable(at: 0)
        tracker.notePrintable(at: 10)
        XCTAssertEqual(tracker.averageGap, 0.1, accuracy: 0.0001, "a 10 s gap is thinking, not typing")
    }

    func test_interruptionBreaksTheGapChain() {
        var tracker = TypingCadenceTracker(averageGap: 0.1)
        tracker.notePrintable(at: 0)
        tracker.noteInterruption()
        tracker.notePrintable(at: 0.9)
        XCTAssertEqual(tracker.averageGap, 0.1, accuracy: 0.0001, "the gap across a click must not count")
    }

    func test_deadlinesScaleWithCadenceAndStayClamped() {
        let fast = TypingCadenceTracker(averageGap: 0.06)
        let slow = TypingCadenceTracker(averageGap: 0.5)

        XCTAssertEqual(fast.commitPause, 0.45, accuracy: 0.0001, "floor: never twitchier than 0.45 s")
        XCTAssertEqual(slow.commitPause, 1.5, accuracy: 0.0001, "ceiling: never lazier than 1.5 s")
        XCTAssertLessThan(fast.singleWordGrace, slow.singleWordGrace)
        XCTAssertLessThan(fast.proposalDuration, slow.proposalDuration)
        XCTAssertLessThan(fast.chipTimeToLive, slow.chipTimeToLive)
        XCTAssertEqual(slow.proposalDuration, 8, accuracy: 0.0001)
        XCTAssertEqual(slow.chipTimeToLive, 15, accuracy: 0.0001)
    }

    func test_defaultCadenceKeepsFamiliarDeadlines() {
        // Unmeasured users should land near the shipped fixed timers, not far
        // from them: 0.18 s gap → 0.72 s commit pause (was 0.6), 0.36 s grace
        // (was 0.3), 4.5 s panel (was 5).
        let tracker = TypingCadenceTracker()
        XCTAssertEqual(tracker.commitPause, 0.72, accuracy: 0.0001)
        XCTAssertEqual(tracker.singleWordGrace, 0.36, accuracy: 0.0001)
        XCTAssertEqual(tracker.proposalDuration, 4.5, accuracy: 0.0001)
    }
}
