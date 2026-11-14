import XCTest
@testable import PapugaCore

final class ProtectedLexiconTests: XCTestCase {
    func test_matcher_protects_known_brand_source() {
        let match = ProtectedLexiconStore.shared.match("payoneer")

        XCTAssertEqual(match?.entry.id, "brand.payoneer")
        XCTAssertEqual(match?.entry.canonical, "Payoneer")
        XCTAssertTrue(match?.protectsSource == true)
        XCTAssertTrue(match?.boostsCandidate == true)
    }

    func test_matcher_matches_domain_label() {
        let match = ProtectedLexiconStore.shared.match("github.com")
        let subdomainMatch = ProtectedLexiconStore.shared.match("docs.github.com")

        XCTAssertEqual(match?.entry.id, "brand.github")
        XCTAssertEqual(match?.mode, .exact)
        XCTAssertEqual(subdomainMatch?.entry.id, "brand.github")
        XCTAssertEqual(subdomainMatch?.mode, .domainLabel)
        XCTAssertTrue(ProtectedLexiconMatcher.isDomainLike("docs.github.com"))
    }

    func test_matcher_keeps_acronyms_case_sensitive() {
        XCTAssertEqual(ProtectedLexiconStore.shared.match("API")?.entry.id, "acronym.api")
        XCTAssertNil(ProtectedLexiconStore.shared.match("api"))
    }

    func test_prediction_scorer_boosts_protected_candidate() {
        let adjustment = ProtectedLexiconPredictionScorer.adjustment(
            original: "зфнщтуук",
            candidate: "payoneer",
            scoreCandidate: 0.35,
            threshold: 0.3
        )

        XCTAssertTrue(adjustment.hasCandidateBoost)
        XCTAssertGreaterThan(adjustment.adjustedCandidateScore, 0.35)
        XCTAssertEqual(adjustment.adjustedThreshold, 0.12, accuracy: 0.001)
        XCTAssertFalse(adjustment.shouldSuppress)
    }

    func test_prediction_scorer_suppresses_protected_source() {
        let adjustment = ProtectedLexiconPredictionScorer.adjustment(
            original: "Payoneer",
            candidate: "Зфнщтуук",
            scoreCandidate: 0.95,
            threshold: 0.3
        )

        XCTAssertTrue(adjustment.shouldSuppress)
        XCTAssertEqual(adjustment.originalMatch?.entry.id, "brand.payoneer")
    }

    func test_grammar_prompt_hints_extract_known_terms() {
        let hints = ProtectedLexiconPredictionScorer.grammarPromptHints(
            text: "Підготуй інструкцію для Payoneer, GitHub і SwiftUI."
        )

        XCTAssertTrue(hints.contains("Payoneer"))
        XCTAssertTrue(hints.contains("GitHub"))
        XCTAssertTrue(hints.contains("SwiftUI"))
    }
}
