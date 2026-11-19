import XCTest
import AppKit
@testable import PapugaKit

/// Diagnostic: does this Mac actually have a Ukrainian spell dictionary, and
/// what does NSSpellChecker really return for `uk`? Gated behind PAPUGA_BENCH.
///
///   TEST_RUNNER_PAPUGA_BENCH=1 xcodebuild test-without-building \
///     -project papuga.xcodeproj -scheme papuga -destination 'platform=macOS' \
///     -only-testing:papugaTests/SpellCheckerLanguageProbeTests
final class SpellCheckerLanguageProbeTests: XCTestCase {

    private func p(_ s: String) { print("PROBE| \(s)") }

    /// Mirrors AutoFixDecision.isCorrectlySpelled.
    private func isCorrect(_ word: String, _ language: String) -> Bool {
        let r = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound || r.length == 0
    }

    private func guesses(_ word: String, _ language: String) -> [String] {
        NSSpellChecker.shared.guesses(
            forWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word, language: language, inSpellDocumentWithTag: 0) ?? []
    }

    func test_probe_ukrainianDictionary() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_BENCH"] == "1",
                          "set PAPUGA_BENCH=1 to run the spell-checker probe")
        let checker = NSSpellChecker.shared

        p("=== AVAILABILITY ===")
        let langs = checker.availableLanguages
        p("availableLanguages (\(langs.count)): \(langs.joined(separator: ", "))")
        for variant in ["uk", "uk_UA", "uk-UA", "ru", "ru_RU", "en", "en_US"] {
            p("  has \"\(variant)\": \(langs.contains(variant))")
        }
        p("automaticallyIdentifiesLanguages=\(checker.automaticallyIdentifiesLanguages)")

        // If a uk dictionary exists, these correct Ukrainian words must NOT be
        // flagged as misspelled.
        let correctUK = ["привіт", "дякую", "робота", "будинок", "українська",
                         "місто", "друг", "комп'ютер", "слово", "добре"]
        p("=== KNOWN-CORRECT UK WORDS (false = flagged WRONG = no/!uk dict) ===")
        var okUK = 0
        for w in correctUK {
            let ok = isCorrect(w, "uk")
            if ok { okUK += 1 }
            p("  uk isCorrect(\"\(w)\") = \(ok)")
        }
        p("UK correct-recognition: \(okUK)/\(correctUK.count)")

        // Control: English in en must mostly be recognized (sanity that the API
        // works at all on this machine).
        let correctEN = ["hello", "computer", "because", "keyboard", "language"]
        var okEN = 0
        for w in correctEN where isCorrect(w, "en") { okEN += 1 }
        p("EN control correct-recognition: \(okEN)/\(correctEN.count)")

        // Guess quality for genuinely-misspelled uk words taken from the real data.
        let misspelledUK = ["вигладати" /*виглядати*/, "зролби" /*зроби*/,
                            "привт" /*привіт*/, "дяку" /*дякую*/, "комптер" /*комп'ютер*/]
        p("=== GUESS QUALITY (uk) ===")
        for w in misspelledUK {
            p("  guesses(uk, \"\(w)\") = \(guesses(w, "uk").prefix(6).joined(separator: ", "))")
        }
        // Compare against ru to detect a silent fallback to a Russian dictionary.
        p("=== SAME WORDS UNDER ru (detect silent fallback) ===")
        for w in misspelledUK {
            p("  guesses(ru, \"\(w)\") = \(guesses(w, "ru").prefix(6).joined(separator: ", "))")
        }

        // Verdict line (machine-readable).
        let hasUKDict = okUK >= correctUK.count * 7 / 10 // ≥70% recognized
        p("VERDICT ukDictionaryUsable=\(hasUKDict) (okUK=\(okUK)/\(correctUK.count), okEN=\(okEN)/\(correctEN.count))")
    }
}
