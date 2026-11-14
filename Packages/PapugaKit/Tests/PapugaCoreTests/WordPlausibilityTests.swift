import XCTest
@testable import PapugaCore

final class WordPlausibilityTests: XCTestCase {

    /// The regression that made this gate worth fixing: `allSatisfy(isLetter)`
    /// rejected every Ukrainian apostrophe form. They were dropped from
    /// candidates, could never be learned as domain vocabulary, and a recorded
    /// apostrophe correction got overridden by a layout guess in `primaryTarget`.
    func test_acceptsUkrainianApostropheForms() {
        for word in ["п'ять", "м'ясо", "об'єкт", "сім'я", "здоров'я", "ім'я", "з'їзд", "комп'ютер"] {
            XCTAssertTrue(WordPlausibility.isWordLike(word), "\(word) should be word-like")
        }
    }

    func test_acceptsTypographicAndModifierApostrophes() {
        XCTAssertTrue(WordPlausibility.isWordLike("п\u{2019}ять"))  // right single quote
        XCTAssertTrue(WordPlausibility.isWordLike("п\u{02BC}ять"))  // modifier letter apostrophe
    }

    func test_acceptsHyphenatedCompounds() {
        for word in ["по-перше", "будь-який", "e-mail", "don't"] {
            XCTAssertTrue(WordPlausibility.isWordLike(word), "\(word) should be word-like")
        }
    }

    /// `здоров'я` is 6 non-vowel characters in a row if the apostrophe counts
    /// as a consonant, so the run counter has to skip connectors.
    func test_apostropheDoesNotCountTowardTheConsonantRun() {
        XCTAssertTrue(WordPlausibility.isWordLike("здоров'я"))
    }

    func test_stillRejectsGibberish() {
        for word in ["gktqhfqn", "dsl;tn", "htgjpbnjhs]", "bcdfg"] {
            XCTAssertFalse(WordPlausibility.isWordLike(word), "\(word) should be rejected")
        }
    }

    /// Connectors are legal only *between* letters — an edge one is punctuation
    /// that BufferedToken has already had its say about.
    func test_rejectsEdgeAndDoubledConnectors() {
        for word in ["'ять", "ять'", "-word", "word-", "a--b", "can''t"] {
            XCTAssertFalse(WordPlausibility.isWordLike(word), "\(word) should be rejected")
        }
    }

    func test_stillRejectsDigitsAndSymbols() {
        for word in ["ab1", "a.b", "a_b", "a;b", "1234"] {
            XCTAssertFalse(WordPlausibility.isWordLike(word), "\(word) should be rejected")
        }
    }

    func test_stillRejectsTooShortAndVowelless() {
        XCTAssertFalse(WordPlausibility.isWordLike("a"))
        XCTAssertFalse(WordPlausibility.isWordLike(""))
        XCTAssertFalse(WordPlausibility.isWordLike("kg"))
    }
}
