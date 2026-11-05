@testable import Diduny
import XCTest

/// Correctness and scaling tests for the live-transcript hot path: the stored
/// (incrementally maintained) `TranscriptSegment.text` must always match the
/// join of its tokens, and per-token cost must not grow with segment length.
@MainActor
final class LiveTranscriptStorePerformanceTests: XCTestCase {
    private func token(
        _ text: String,
        isFinal: Bool = true,
        speaker: String? = "1",
        startMs: Int = 0
    ) -> RealtimeToken {
        RealtimeToken(text: text, isFinal: isFinal, speaker: speaker, startMs: startMs)
    }

    func testFinalTextOmitsSpeakerLabelWhenEngineHasNone() {
        let store = LiveTranscriptStore()
        store.speakerLabels = false
        store.processTokens([RealtimeToken(text: "hello there", isFinal: true)])
        XCTAssertFalse(store.finalTranscriptText.contains("Unknown"))
        XCTAssertTrue(store.finalTranscriptText.hasSuffix("] hello there"))
    }

    func testStoredSegmentTextMatchesJoinedTokens() {
        let store = LiveTranscriptStore()
        let tokens = (0 ..< 500).map { token($0 % 7 == 0 ? " word\($0)" : "x") }
        store.processTokens(tokens)

        XCTAssertEqual(store.segments.count, 1)
        let segment = store.segments[0]
        XCTAssertEqual(segment.text, segment.tokens.map(\.text).joined())
    }

    func testSpeakerChangeStartsNewSegmentWithCorrectText() {
        let store = LiveTranscriptStore()
        store.processTokens([token("hello ", speaker: "1"), token("world", speaker: "1")])
        store.processTokens([token("hi ", speaker: "2"), token("there", speaker: "2")])

        XCTAssertEqual(store.segments.count, 2)
        XCTAssertEqual(store.segments[0].text, "hello world")
        XCTAssertEqual(store.segments[1].text, "hi there")
    }

    func testSegmentBoundaryForcesNewSegmentAndPreservesText() {
        let store = LiveTranscriptStore()
        store.processTokens([token("first")])
        store.markSegmentBoundary()
        store.processTokens([token("second")])

        XCTAssertEqual(store.segments.count, 2)
        XCTAssertEqual(store.segments[0].text, "first")
        XCTAssertEqual(store.segments[1].text, "second")
    }

    func testFinalTranscriptTextIncludesAllSegments() {
        let store = LiveTranscriptStore()
        store.processTokens([token("alpha", speaker: "1", startMs: 0)])
        store.processTokens([token("beta", speaker: "2", startMs: 65000)])

        let text = store.finalTranscriptText
        XCTAssertTrue(text.contains("Speaker 1: alpha"))
        XCTAssertTrue(text.contains("Speaker 2: beta"))
        XCTAssertTrue(text.contains("[01:05]"))
    }

    /// Appending into one long segment must stay cheap regardless of how much
    /// text the segment already holds. Before text was stored incrementally,
    /// 20k tokens in one segment took quadratic time via re-joins per render;
    /// the raw append path measured here must scale linearly.
    func testLongSingleSpeakerSegmentAppendScalesLinearly() {
        let store = LiveTranscriptStore()
        let batch = (0 ..< 100).map { _ in token("word ") }

        measure {
            for _ in 0 ..< 200 {
                store.processTokens(batch)
            }
        }

        XCTAssertGreaterThanOrEqual(store.segments[0].tokens.count, 20_000)
        // Reading the full text afterwards is a single O(length) pass.
        XCTAssertTrue(store.finalTranscriptText.hasSuffix("word"))
    }
}
