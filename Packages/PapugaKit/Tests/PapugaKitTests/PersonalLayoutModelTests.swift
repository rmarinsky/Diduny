import XCTest
@testable import PapugaKit

final class PersonalLayoutModelTests: XCTestCase {
    func test_retainedHistoryDoesNotRevalidateUnchangedEntries() {
        let model = PersonalLayoutModel()
        var history = (0..<2000).map { index in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(index * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from, targetLayoutID: to, verificationSucceeded: true)
        }
        model.replaceHistory(history)
        XCTAssertEqual(model.validatedEntryCount, 2000)
        history.append(ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: 2000 * 86400),
            kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
            sourceLayoutID: from, targetLayoutID: to, verificationSucceeded: true))
        let start = Date()
        model.replaceHistory(history)
        print("Personal history incremental update ms: \(Date().timeIntervalSince(start) * 1000)")
        XCTAssertEqual(model.validatedEntryCount, 2001, "Only the new record should invoke layout validation")
        model.replaceHistory([])
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
    }

    func test_legacyUnverifiedHistoryDoesNotTeach() {
        let model = PersonalLayoutModel()
        model.replaceHistory((0..<4).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from, targetLayoutID: to)
        })
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
    }

    func test_failedInsertionsNeverTeachLayoutPairs() {
        let model = PersonalLayoutModel()
        model.replaceHistory((0..<4).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from, targetLayoutID: to, verificationSucceeded: false)
        })
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
    }

    func test_undoingPhraseRemovesEarlierWordAndContextEvidence() {
        let model = PersonalLayoutModel()
        var history = (0..<3).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from, targetLayoutID: to, verificationSucceeded: true)
        }
        history.append(ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: 300000),
            kind: .autoFixUndone, original: "lfdfq dct", converted: "давай все", sourceLayoutID: from))
        model.replaceHistory(history)
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
        XCTAssertEqual(model.boost(original: "dct", candidate: "все", sourceID: from, targetID: to, previousWord: "lfdfq"), 0)
    }

    func test_retriesIncompleteTokensAndClearedHistoryDoNotTeach() {
        let model = PersonalLayoutModel()
        let retries = (0..<3).map { second in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(second)),
                kind: .manualSwitch, original: "lfdfq dct", converted: "давай все",
                sourceLayoutID: from, targetLayoutID: to, bundleID: "test.editor", verificationSucceeded: true)
        }
        model.replaceHistory(retries)
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
        XCTAssertEqual(model.boost(original: "dct", candidate: "все", sourceID: from, targetID: to), 0)
        model.replaceHistory((0..<3).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq ", converted: "давай ", sourceLayoutID: from, targetLayoutID: to, verificationSucceeded: true)
        })
        XCTAssertGreaterThan(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
        model.replaceHistory([])
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
    }

    private let from = "com.apple.keylayout.US"
    private let to = "com.apple.keylayout.Ukrainian-PC"

    func test_repeatedManualPhrasesTeachCompletedWordPairs() {
        let model = PersonalLayoutModel()
        let history = (0..<3).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from, targetLayoutID: to, bundleID: "test.editor", verificationSucceeded: true)
        }
        model.replaceHistory(history)
        XCTAssertGreaterThan(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
        XCTAssertGreaterThan(model.boost(original: "dct", candidate: "все", sourceID: from, targetID: to, previousWord: "lfdfq"), 0)
        XCTAssertEqual(model.boost(original: "dct", candidate: "всі", sourceID: from, targetID: to), 0)
    }
}
