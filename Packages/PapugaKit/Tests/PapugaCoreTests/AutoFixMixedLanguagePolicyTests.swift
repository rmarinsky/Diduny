import XCTest
@testable import PapugaCore

final class AutoFixMixedLanguagePolicyTests: XCTestCase {
    func test_classifier_skips_common_acronyms() {
        XCTAssertEqual(AutoFixTokenClassifier.classify("API"), .acronym)
        XCTAssertEqual(AutoFixTokenClassifier.classify("QA"), .acronym)
        XCTAssertEqual(AutoFixTokenClassifier.classify("REST"), .acronym)
        XCTAssertEqual(AutoFixTokenClassifier.classify("JSON"), .acronym)
    }

    func test_classifier_skips_product_terms() {
        XCTAssertEqual(AutoFixTokenClassifier.classify("iOS"), .productTerm)
        XCTAssertEqual(AutoFixTokenClassifier.classify("macOS"), .productTerm)
        XCTAssertEqual(AutoFixTokenClassifier.classify("SwiftUI"), .productTerm)
        XCTAssertEqual(AutoFixTokenClassifier.classify("GitHub"), .productTerm)
    }

    func test_classifier_skips_code_like_tokens() {
        XCTAssertEqual(AutoFixTokenClassifier.classify("xcodebuild"), .codeLike)
        XCTAssertEqual(AutoFixTokenClassifier.classify("localhost"), .codeLike)
        XCTAssertEqual(AutoFixTokenClassifier.classify("src/App.swift"), .codeLike)
        XCTAssertEqual(AutoFixTokenClassifier.classify("my_variable"), .identifier)
        XCTAssertEqual(AutoFixTokenClassifier.classify("my-token"), .identifier)
    }

    func test_policy_skips_latin_intentional_terms() {
        let decision = AutoFixMixedLanguagePolicy.decision(
            original: "API",
            candidate: "ФЗШ",
            currentLanguage: "en",
            targetLanguage: "uk",
            scoreOriginal: 0.1,
            scoreCandidate: 0.9,
            threshold: 0.3
        )

        XCTAssertEqual(decision, .skipAsIntentional(.acronym))
    }

    func test_policy_does_not_skip_wrong_layout_cyrillic_for_english() {
        let decision = AutoFixMixedLanguagePolicy.decision(
            original: "црут",
            candidate: "when",
            currentLanguage: "uk",
            targetLanguage: "en",
            scoreOriginal: 0.1,
            scoreCandidate: 0.8,
            threshold: 0.3
        )

        XCTAssertEqual(decision, .autoReplace)
    }

    func test_policy_proposes_ambiguous_margin() {
        let decision = AutoFixMixedLanguagePolicy.decision(
            original: "ghbdtn",
            candidate: "привіт",
            currentLanguage: "en",
            targetLanguage: "uk",
            scoreOriginal: 0.2,
            scoreCandidate: 0.35,
            threshold: 0.3
        )

        XCTAssertEqual(decision, .propose)
    }
}
