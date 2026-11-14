import XCTest
@testable import PapugaKit

final class ManualReplacementSnapshotTests: XCTestCase {
    func test_acceptsOnlyExactInsertionWithPreservedSurroundingTextAndCaret() {
        let range = NSRange(location: 3, length: 3)
        XCTAssertTrue(ManualReplacementSnapshot.confirms(before: "hi abc tail", range: range,
            original: "abc", replacement: "привіт", after: "hi привіт tail", caret: 9))
        XCTAssertFalse(ManualReplacementSnapshot.confirms(before: "hi abc tail", range: range,
            original: "abc", replacement: "привіт", after: "hi abc tail", caret: 6))
        XCTAssertFalse(ManualReplacementSnapshot.confirms(before: "hi abc tail", range: range,
            original: "abc", replacement: "привіт", after: "hi привіт", caret: 9))
        XCTAssertFalse(ManualReplacementSnapshot.confirms(before: "hi abc tail", range: range,
            original: "abc", replacement: "привіт", after: "hi привіт tail", caret: 3))
    }

    func test_partialIdentifierAndContractionCannotTeachAWholeWord() {
        for suffix in ["1", "_name", "’s", "-name"] {
            XCTAssertFalse(ManualReplacementSnapshot.confirms(before: "abc" + suffix,
                range: NSRange(location: 0, length: 3), original: "abc", replacement: "привіт",
                after: "привіт" + suffix, caret: 6))
        }
    }

    func test_rejectsPartialWordsAndInvalidRanges() {
        XCTAssertFalse(ManualReplacementSnapshot.confirms(before: "abcdef", range: NSRange(location: 0, length: 3),
            original: "abc", replacement: "привіт", after: "привітdef", caret: 6))
        XCTAssertFalse(ManualReplacementSnapshot.confirms(before: "abc", range: NSRange(location: 0, length: 40),
            original: "abc", replacement: "привіт", after: "привіт", caret: 6))
    }
}
