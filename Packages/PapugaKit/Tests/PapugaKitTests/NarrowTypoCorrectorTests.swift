import Carbon.HIToolbox
import XCTest
@testable import PapugaKit

final class NarrowTypoCorrectorTests: XCTestCase {
    private struct Checker: SpellCheckingClient {
        var known: [String: Int] = [:]
        var learned: Set<String> = []
        var suggestions: [String: [String]] = [:]
        func isExplicitlyKnown(_ word: String, language: String) -> Bool { learned.contains(word) }
        func logFrequency(of word: String, language: String) -> Double {
            known[word].map { log10(1 + Double($0)) } ?? 0
        }
        func isMisspelled(_ word: String, language: String) -> Bool { known[word] == nil && !learned.contains(word) }
        func guesses(for word: String, language: String) -> [String] { suggestions[word] ?? [] }
    }

    private let keys: [Character: Int] = [
        "q": kVK_ANSI_Q, "w": kVK_ANSI_W, "e": kVK_ANSI_E, "r": kVK_ANSI_R, "t": kVK_ANSI_T,
        "a": kVK_ANSI_A, "s": kVK_ANSI_S, "d": kVK_ANSI_D, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "h": kVK_ANSI_H, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "i": kVK_ANSI_I
    ]

    private func correct(_ word: String, _ checker: Checker) -> String? {
        NarrowTypoCorrector.correction(for: word, language: "en", spellChecker: checker,
                                       keyCode: { self.keys[$0].map(UInt16.init) })
    }

    func testFixesTranspositionAndNeighbourKeyWithOneCommonCandidate() {
        let checker = Checker(known: ["there": 9000, "world": 9000],
                              suggestions: ["tehre": ["there"], "worls": ["world"]])
        XCTAssertEqual(correct("tehre", checker), "there")
        XCTAssertEqual(correct("Tehre", checker), "There")
        // s sits beside d.
        XCTAssertEqual(correct("worls", checker), "world")
    }

    func testLeavesEverythingOutsideTheClassAlone() {
        var checker = Checker(known: ["there": 9000, "three": 9000, "hello": 9000, "world": 9000, "rare": 5],
                              suggestions: ["tehre": ["there", "three"], "helo": ["hello"], "hellp": ["hello"],
                                            "worlm": ["world"], "raer": ["rare"], "theer": ["there"]])
        // Two words one edit away — ambiguous. (`three` is two edits; make it one.)
        checker.suggestions["thre"] = ["there", "three"]
        XCTAssertNil(correct("thre", checker))
        // Too short, a missing letter, a far-away key, a rare target.
        XCTAssertNil(correct("helo", checker))
        XCTAssertNil(correct("worlm", checker))
        XCTAssertNil(correct("raers", checker))
        // p is beside o, not beside the intended o→p swap target: substitution o/p is a neighbour.
        XCTAssertEqual(correct("hellp", checker), "hello")
        // Shouted or mixed-case tokens are names and acronyms.
        XCTAssertNil(correct("TEHRE", checker))
        // A word the user taught Papuga is never rewritten.
        checker.learned = ["theer"]
        XCTAssertNil(correct("theer", checker))
    }

    func testNeighbourKeysAreSameRowOnly() {
        XCTAssertTrue(NarrowTypoCorrector.areNeighbourKeys(UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_D)))
        XCTAssertFalse(NarrowTypoCorrector.areNeighbourKeys(UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_W)))
        XCTAssertFalse(NarrowTypoCorrector.areNeighbourKeys(UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_F)))
    }
}
