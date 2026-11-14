import XCTest
@testable import PapugaKit

final class LanguageScorerTests: XCTestCase {
    func test_localScorerPrefersRealWordsOverWrongLayoutText() {
        let scorer = LanguageScorerFactory.make(.appleNL)
        for (original, candidate, source, target) in [
            ("рфі", "has", "uk", "en"),
            ("lfdfq", "давай", "en", "uk"),
            ("dct", "все", "en", "uk"),
            ("рфі учзшкшутсу ещ", "has expirience to", "uk", "en")
        ] {
            XCTAssertGreaterThan(scorer.score(candidate, expecting: target),
                                 scorer.score(original, expecting: source) + 0.35,
                                 "Must favour the intended words: \(original) → \(candidate)")
        }
    }

    func test_AppleNL_scores_uk_word_higher_for_uk() {
        let scorer = AppleNLScorer()
        let scoreUK = scorer.score("Україна", expecting: "uk")
        let scoreEN = scorer.score("Україна", expecting: "en")
        XCTAssertGreaterThan(scoreUK, scoreEN)
    }

    func test_AppleNL_scores_en_word_higher_for_en() {
        let scorer = AppleNLScorer()
        let scoreEN = scorer.score("hello world", expecting: "en")
        let scoreUK = scorer.score("hello world", expecting: "uk")
        XCTAssertGreaterThan(scoreEN, scoreUK)
    }

    func test_AppleNL_scores_ru_word_higher_for_ru() {
        let scorer = AppleNLScorer()
        let scoreRU = scorer.score("привет мир", expecting: "ru")
        let scoreEN = scorer.score("привет мир", expecting: "en")
        XCTAssertGreaterThan(scoreRU, scoreEN)
    }

    func test_all_algorithms_pick_uk_for_uk_word() {
        for algo in LanguageScorerAlgorithm.allCases {
            let scorer = LanguageScorerFactory.make(algo)
            let scoreUK = scorer.score("Україна та Київ", expecting: "uk")
            let scoreEN = scorer.score("Україна та Київ", expecting: "en")
            XCTAssertGreaterThan(scoreUK, scoreEN, "Algorithm \(algo.rawValue) failed to favour Ukrainian")
        }
    }

    func test_all_algorithms_pick_en_for_real_en_word() {
        for algo in LanguageScorerAlgorithm.allCases {
            let scorer = LanguageScorerFactory.make(algo)
            let scoreEN = scorer.score("hello", expecting: "en")
            let scoreUK = scorer.score("hello", expecting: "uk")
            XCTAssertGreaterThanOrEqual(scoreEN, scoreUK, "Algorithm \(algo.rawValue) should not favour Ukrainian for 'hello'")
        }
    }

    func test_empty_text_returns_zero() {
        let scorer = AppleNLScorer()
        XCTAssertEqual(scorer.score("", expecting: "en"), 0)
    }

    func test_decision_picks_candidate_when_target_is_real_word() {
        let scorer = AppleNLScorer()
        // ".hsq" is gibberish in EN, "юрій" is a real UA name
        let scoreOriginalEN = scorer.score(".hsq", expecting: "en")
        let scoreCandidateUK = scorer.score("юрій", expecting: "uk")
        XCTAssertTrue(
            AutoFixDecision.shouldReplace(
                scoreOriginal: scoreOriginalEN,
                scoreCandidate: scoreCandidateUK,
                threshold: 0.4
            ),
            "Expected replacement for '.hsq' → 'юрій' (scores: \(scoreOriginalEN) vs \(scoreCandidateUK))"
        )
    }

    func test_decision_picks_candidate_for_buv_ti_tut() {
        let scorer = AppleNLScorer()
        let scoreOriginalEN = scorer.score(",ed nb nen", expecting: "en")
        let scoreCandidateUK = scorer.score("був ти тут", expecting: "uk")
        XCTAssertTrue(
            AutoFixDecision.shouldReplace(
                scoreOriginal: scoreOriginalEN,
                scoreCandidate: scoreCandidateUK,
                threshold: 0.4
            ),
            "Expected replacement for ',ed nb nen' → 'був ти тут' (scores: \(scoreOriginalEN) vs \(scoreCandidateUK))"
        )
    }

    func test_decision_keeps_original_for_real_english_word() {
        let scorer = AppleNLScorer()
        let scoreOriginalEN = scorer.score("hello", expecting: "en")
        // What "hello" maps to in Ukrainian-PC isn't a real Ukrainian word — synthesise candidate score 0.
        let scoreCandidateUK = scorer.score("руддщ", expecting: "uk")
        XCTAssertFalse(
            AutoFixDecision.shouldReplace(
                scoreOriginal: scoreOriginalEN,
                scoreCandidate: scoreCandidateUK,
                threshold: 0.4
            ),
            "'hello' should NOT be auto-fixed (scores: \(scoreOriginalEN) vs \(scoreCandidateUK))"
        )
    }
}
