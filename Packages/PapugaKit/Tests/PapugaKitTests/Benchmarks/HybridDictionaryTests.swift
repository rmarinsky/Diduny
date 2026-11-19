import XCTest
@testable import PapugaKit

/// System double that flags everything as misspelled and returns a fixed guess.
private final class AllWrongSpellChecker: SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool { true }
    func guesses(for word: String, language: String) -> [String] { ["systemguess"] }
}

private final class AllCorrectSpellChecker: SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool { false }
    func guesses(for word: String, language: String) -> [String] { [] }
}

private final class SelectiveSpellChecker: SpellCheckingClient {
    private let accepted: Set<String>

    init(accepted: Set<String>) {
        self.accepted = accepted
    }

    func isMisspelled(_ word: String, language: String) -> Bool {
        !accepted.contains(word.lowercased())
    }

    func guesses(for word: String, language: String) -> [String] { [] }
}

final class HybridDictionaryTests: XCTestCase {

    /// Sizes reflect the filtered lists (see Resources/FrequencyWords/NOTICE.md):
    /// the raw 50k dumps are cut down to what the macOS dictionary accepts,
    /// which removes 18,904 uk entries — most of them Russian.
    func test_bundledFrequencyDictionariesLoad() {
        XCTAssertGreaterThan(DictionaryBuilder.loadBundledBase(language: "uk").count, 25_000)
        XCTAssertGreaterThan(DictionaryBuilder.loadBundledBase(language: "en").count, 34_000)
    }

    /// The `#` comment markers in the hand-edited supplement must not become
    /// dictionary words.
    func test_bundledBaseSkipsCommentLines() {
        let uk = DictionaryBuilder.loadBundledBase(language: "uk")
        XCTAssertFalse(uk.contains { $0.0.hasPrefix("#") })
        XCTAssertFalse(uk.contains { $0.0.isEmpty })
    }

    func test_builder_parse() {
        let parsed = DictionaryBuilder.parse("hello 100\nworld 50\nlone\n")
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].0, "hello"); XCTAssertEqual(parsed[0].1, 100)
        XCTAssertEqual(parsed[2].0, "lone"); XCTAssertEqual(parsed[2].1, 1) // no count → 1
    }

    func test_builder_learnedFrequencies_normalizesAndCountsPerLanguage() {
        let learned = DictionaryBuilder.learnedFrequencies(from: [
            ("Дев", "uk"), ("дев.", "uk"), ("дев", "uk"), ("hello", "en"),
        ])
        let uk = Dictionary(uniqueKeysWithValues: learned["uk"] ?? [])
        XCTAssertEqual(uk["дев"], 3)            // Дев / дев. / дев all normalize together
        XCTAssertEqual(learned["en"]?.first?.0, "hello")
    }

    func test_builder_build_combinesBaseAndLearnedWithWeight() {
        let indexes = DictionaryBuilder.build(
            base: ["uk": [("привіт", 1)]],
            learned: ["uk": [("дев", 1)]],
            learnedWeight: 1000
        )
        let uk = indexes["uk"]
        XCTAssertNotNil(uk)
        XCTAssertEqual(uk?.words["привіт"], 1)
        XCTAssertEqual(uk?.words["дев"], 1000)  // learned weighted up
    }

    func test_hybrid_learnedKnown_onlyRemovesFalsePositives() {
        let hybrid = HybridSpellChecker(
            system: AllWrongSpellChecker(),
            learnedKnown: ["uk": ["дев"]]
        )
        // The user's own word is now "known" → not flagged.
        XCTAssertFalse(hybrid.isMisspelled("дев", language: "uk"))
        XCTAssertFalse(hybrid.isMisspelled("ДЕВ", language: "uk")) // case-insensitive
        // Anything else still defers to the (authoritative) system checker.
        XCTAssertTrue(hybrid.isMisspelled("кнокп", language: "uk"))
    }

    func test_hybrid_normalizesUkrainianApostropheVariantsForExplicitVocabulary() {
        let indexes = DictionaryBuilder.build(base: ["uk": [("п'ять", 16)]], learned: [:])
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker(), indexes: indexes)

        XCTAssertTrue(hybrid.isExplicitlyKnown("п'ять", language: "uk"))
        XCTAssertTrue(hybrid.isExplicitlyKnown("пʼять", language: "uk"))
        XCTAssertTrue(hybrid.isExplicitlyKnown("п’ять", language: "uk"))
    }

    func test_hybrid_guesses_putSymSpellCorrectionsFirst() {
        let indexes = DictionaryBuilder.build(
            base: ["uk": [("привіт", 100)]],
            learned: [:]
        )
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker(), indexes: indexes)
        let guesses = hybrid.guesses(for: "привт", language: "uk")
        XCTAssertEqual(guesses.first, "привіт")          // SymSpell correction first
        XCTAssertTrue(guesses.contains("systemguess"))   // system guess still merged in
    }

    /// Some macOS runners report a dictionary but accept every token. That is
    /// not spelling evidence: fall back to explicit bundled or learned words.
    func test_hybrid_unreliableSystemFallsBackToExplicitVocabulary() {
        let indexes = DictionaryBuilder.build(
            base: ["uk": [("привіт", 100)]],
            learned: [:]
        )
        let hybrid = HybridSpellChecker(system: AllCorrectSpellChecker(), indexes: indexes)

        XCTAssertFalse(hybrid.isMisspelled("привіт", language: "uk"))
        XCTAssertEqual(hybrid.mappedSpellingStatus("привіт", language: "uk"), .correct)
        XCTAssertTrue(hybrid.isMisspelled("привчт", language: "uk"))
        XCTAssertEqual(hybrid.mappedSpellingStatus("привчт", language: "uk"), .unavailable)
    }

    func test_hybrid_reliableSystemStillAcceptsUncommonWordsOutsideIndex() {
        let indexes = DictionaryBuilder.build(base: ["uk": [("привіт", 100)]], learned: [:])
        let hybrid = HybridSpellChecker(
            system: SelectiveSpellChecker(accepted: ["рідковживане"]),
            indexes: indexes
        )

        XCTAssertFalse(hybrid.isMisspelled("рідковживане", language: "uk"))
        XCTAssertEqual(hybrid.mappedSpellingStatus("рідковживане", language: "uk"), .correct)
    }

    func test_hybrid_systemRejectionStillFailsClosed() {
        let indexes = DictionaryBuilder.build(base: ["uk": [("привіт", 100)]], learned: [:])
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker(), indexes: indexes)

        // Index promotes it even though the system rejects everything.
        XCTAssertEqual(hybrid.mappedSpellingStatus("привіт", language: "uk"), .correct)
        // Nothing vouches for this one and the system rejects it → suppress.
        XCTAssertEqual(hybrid.mappedSpellingStatus("кнокп", language: "uk"), .misspelled)
    }

    /// A learned word is correct even when neither the index nor the system
    /// knows it — that is the whole point of the overlay.
    func test_hybrid_learnedOverlayPromotesWithoutAnIndex() {
        let hybrid = HybridSpellChecker(
            system: AllWrongSpellChecker(),
            learnedKnown: ["uk": ["пофіксити"]]
        )
        XCTAssertEqual(hybrid.mappedSpellingStatus("пофіксити", language: "uk"), .correct)
        XCTAssertEqual(hybrid.mappedSpellingStatus("ПОФІКСИТИ", language: "uk"), .correct)
    }

    /// Without an index the system checker is the authority — which is what
    /// this test always claimed to assert. It previously reported
    /// `.unavailable` instead, so every layout replacement into a language with
    /// no bundled index (ru, pl, de, fr…) was suppressed outright.
    func test_hybrid_withoutIndexFallsBackToSystem() throws {
        try XCTSkipUnless(
            HybridSpellChecker.systemSupports("fr"),
            "macOS on this machine has no French dictionary"
        )
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker())
        XCTAssertTrue(hybrid.isMisspelled("anything", language: "fr"))
        XCTAssertEqual(hybrid.guesses(for: "anything", language: "fr"), ["systemguess"])
        XCTAssertEqual(hybrid.mappedSpellingStatus("anything", language: "fr"), .misspelled)
    }

    /// `.unavailable` now means "no authority can answer", not "no SymSpell
    /// index". Asking NSSpellChecker about a language it does not support
    /// silently falls back to automatic detection and returns nonsense, so that
    /// case has to stay distinguishable from a real verdict.
    func test_hybrid_unsupportedLanguageIsUnavailableRatherThanMisspelled() {
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker())
        XCTAssertFalse(HybridSpellChecker.systemSupports("zz"))
        XCTAssertEqual(hybrid.mappedSpellingStatus("anything", language: "zz"), .unavailable)
    }

    func test_systemSupports_matchesOnTheBaseLanguageCode() {
        // macOS reports regional variants like "en_GB"; a bare "en" must match.
        XCTAssertTrue(HybridSpellChecker.systemSupports("en"))
        XCTAssertTrue(HybridSpellChecker.systemSupports("en_US"))
        XCTAssertFalse(HybridSpellChecker.systemSupports(""))
    }

    /// The upstream list has zero apostrophe forms; the supplement supplies
    /// them so they carry a frequency signal for ranking. (They spell correctly
    /// either way — macOS knows them — but without a count they sort last among
    /// equally-distant guesses.)
    func test_supplementSuppliesApostropheForms() {
        let words = Set(DictionaryBuilder.loadBundledBase(language: "uk").map(\.0))
        for word in ["п'ять", "м'ясо", "об'єкт", "сім'я", "здоров'я", "ім'я", "комп'ютер"] {
            XCTAssertTrue(words.contains(word), "\(word) missing from the bundled uk vocabulary")
        }
    }

    /// The regenerated list must not readmit Russian as valid Ukrainian.
    func test_ukrainianListNoLongerCarriesRussian() {
        let words = Set(DictionaryBuilder.loadBundledBase(language: "uk").map(\.0))
        for word in ["что", "это", "если", "тебя", "ничего", "пожалуйста"] {
            XCTAssertFalse(words.contains(word), "\(word) is Russian and must not be in the uk list")
        }
        // Genuinely shared words must survive — this is why the filter defers
        // to the macOS dictionary instead of subtracting a Russian lexicon.
        for word in ["так", "він", "тебе", "привіт", "дякую"] {
            XCTAssertTrue(words.contains(word), "\(word) was over-filtered out of the uk list")
        }
    }
}
