import XCTest
import Carbon.HIToolbox
@testable import PapugaKit

/// Mapping, language scoring, and decision integration tests.
/// These do not exercise AutoFixController, event capture, proposals, or text insertion.
/// Input-source availability can cause skips on other Macs.
final class MultiLanguageScoringIntegrationTests: XCTestCase {
    private struct AutoFixCase {
        let label: String
        let typedInWrongLayout: String
        let expectedCorrected: String
        let fromLayoutID: String
        let toLayoutID: String
        let expectedFix: Bool
    }

    private var mapper = CharacterMapper()

    override func setUp() {
        super.setUp()
        mapper = CharacterMapper()
    }

    private func source(forID id: String) throws -> TISInputSource {
        let conditions = [kTISPropertyInputSourceID!: id as CFString] as CFDictionary
        guard let list = TISCreateInputSourceList(conditions, true)?.takeRetainedValue() as? [TISInputSource],
              let s = list.first else {
            throw XCTSkip("Input source \(id) not present on this Mac.")
        }
        return s
    }

    private func assertScoringDecision(_ tc: AutoFixCase, algorithm: LanguageScorerAlgorithm, threshold: Double = 0.3) throws {
        let fromSrc = try source(forID: tc.fromLayoutID)
        let toSrc = try source(forID: tc.toLayoutID)
        mapper.buildMap(for: fromSrc, sourceID: tc.fromLayoutID)
        mapper.buildMap(for: toSrc, sourceID: tc.toLayoutID)

        let candidate = mapper.convert(text: tc.typedInWrongLayout, fromSourceID: tc.fromLayoutID, toSourceID: tc.toLayoutID)
        XCTAssertEqual(
            candidate.lowercased(),
            tc.expectedCorrected.lowercased(),
            "[\(tc.label)] mapping wrong: '\(tc.typedInWrongLayout)' → '\(candidate)' (expected '\(tc.expectedCorrected)')"
        )

        // These fixtures document the raw AppleNL backend. The persisted appleNL
        // setting now selects the local engine, covered by AutoFixTypingCorpusTests.
        let scorer: LanguageScorer = algorithm == .appleNL ? AppleNLScorer() : LanguageScorerFactory.make(algorithm)
        let fromLang = AutoFixDecision.languageHintForLayoutID(tc.fromLayoutID)
        let toLang = AutoFixDecision.languageHintForLayoutID(tc.toLayoutID)
        let scoreOriginal = scorer.score(tc.typedInWrongLayout, expecting: fromLang)
        let scoreCandidate = scorer.score(candidate, expecting: toLang)

        let shouldFix = AutoFixDecision.shouldReplace(
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: threshold
        )

        XCTAssertEqual(
            shouldFix,
            tc.expectedFix,
            "[\(tc.label)/\(algorithm.rawValue)] decision wrong for '\(tc.typedInWrongLayout)' → '\(candidate)' (scores: orig=\(scoreOriginal) cand=\(scoreCandidate))"
        )
    }

    // MARK: - Russian (positive: Cyrillic-script signal is very strong)

    private static let russianPositiveCases: [AutoFixCase] = [
        AutoFixCase(label: "RU.privet",
                    typedInWrongLayout: "ghbdtn", expectedCorrected: "привет",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Russian",
                    expectedFix: true),
        AutoFixCase(label: "RU.spasibo",
                    typedInWrongLayout: "cgfcb,j", expectedCorrected: "спасибо",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Russian",
                    expectedFix: true),
        AutoFixCase(label: "RU.byl_li_ti_tut",
                    typedInWrongLayout: ",sk kb ns nen", expectedCorrected: "был ли ты тут",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Russian",
                    expectedFix: true)
    ]

    func test_russian_positive_with_appleNL() throws {
        for tc in Self.russianPositiveCases { try assertScoringDecision(tc, algorithm: .appleNL) }
    }

    // MARK: - Ukrainian (positive: same as RU, very strong signal)

    private static let ukrainianPositiveCases: [AutoFixCase] = [
        AutoFixCase(label: "UA.juriy",
                    typedInWrongLayout: ".hsq", expectedCorrected: "юрій",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: true),
        AutoFixCase(label: "UA.buv_ti_tut",
                    typedInWrongLayout: ",ed nb nen", expectedCorrected: "був ти тут",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: true),
        AutoFixCase(label: "UA.dyakuyu",
                    typedInWrongLayout: "ghbdsn", expectedCorrected: "привіт",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: true),
        // Regression for the user-reported case: word 'важливо' typed via EN keys
        // contains ';' (which is the key for 'ж' in Ukrainian-PC). The buffer must
        // NOT split at the semicolon.
        AutoFixCase(label: "UA.vazhlyvo_with_semicolon",
                    typedInWrongLayout: "df;kbdj", expectedCorrected: "важливо",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: true)
    ]

    func test_ukrainian_positive_with_appleNL() throws {
        for tc in Self.ukrainianPositiveCases { try assertScoringDecision(tc, algorithm: .appleNL) }
    }

    // MARK: - English typed while Ukrainian layout is active

    private static let englishFromUkrainianPositiveCases: [AutoFixCase] = [
        AutoFixCase(label: "EN.when_from_UA",
                    typedInWrongLayout: "црут", expectedCorrected: "when",
                    fromLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    toLayoutID: "com.apple.keylayout.US",
                    expectedFix: true),
        AutoFixCase(label: "EN.user_phrase_when_i_do_the_mistackets",
                    typedInWrongLayout: "црут ш вщ еру ьшіефслуеі", expectedCorrected: "when i do the mistackets",
                    fromLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    toLayoutID: "com.apple.keylayout.US",
                    expectedFix: true)
    ]

    func test_english_from_ukrainian_positive_with_appleNL() throws {
        for tc in Self.englishFromUkrainianPositiveCases { try assertScoringDecision(tc, algorithm: .appleNL) }
    }

    // MARK: - Negative: native English phrases must NOT be auto-fixed

    private static let englishNegativeCases: [AutoFixCase] = [
        // Multi-word EN phrase. Apple NL is highly confident in English.
        AutoFixCase(label: "EN.hello_world_RU",
                    typedInWrongLayout: "hello world", expectedCorrected: "руддщ цщкдв",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Russian",
                    expectedFix: false),
        AutoFixCase(label: "EN.thank_you_UA",
                    typedInWrongLayout: "thank you very much", expectedCorrected: "ерфтлюоуєрутцн",  // placeholder, mapping computed live
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: false)
    ]

    /// English phrases should NOT auto-fix to Cyrillic. The expectedCorrected for the
    /// EN.thank_you_UA case isn't asserted exactly because the only thing that matters
    /// is the decision: don't fix. We override the runner to skip the mapping equality
    /// check by passing the actual mapping back through.
    private func runNoFixDecisionOnly(_ tc: AutoFixCase, algorithm: LanguageScorerAlgorithm) throws {
        let fromSrc = try source(forID: tc.fromLayoutID)
        let toSrc = try source(forID: tc.toLayoutID)
        mapper.buildMap(for: fromSrc, sourceID: tc.fromLayoutID)
        mapper.buildMap(for: toSrc, sourceID: tc.toLayoutID)

        let candidate = mapper.convert(text: tc.typedInWrongLayout, fromSourceID: tc.fromLayoutID, toSourceID: tc.toLayoutID)

        // These fixtures document the raw AppleNL backend. The persisted appleNL
        // setting now selects the local engine, covered by AutoFixTypingCorpusTests.
        let scorer: LanguageScorer = algorithm == .appleNL ? AppleNLScorer() : LanguageScorerFactory.make(algorithm)
        let fromLang = AutoFixDecision.languageHintForLayoutID(tc.fromLayoutID)
        let toLang = AutoFixDecision.languageHintForLayoutID(tc.toLayoutID)
        let scoreOriginal = scorer.score(tc.typedInWrongLayout, expecting: fromLang)
        let scoreCandidate = scorer.score(candidate, expecting: toLang)

        let shouldFix = AutoFixDecision.shouldReplace(
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: 0.3
        )
        XCTAssertFalse(
            shouldFix,
            "[\(tc.label)/\(algorithm.rawValue)] should NOT auto-fix '\(tc.typedInWrongLayout)' → '\(candidate)' (orig=\(scoreOriginal) cand=\(scoreCandidate))"
        )
    }

    func test_english_phrases_not_autofixed_with_appleNL() throws {
        for tc in Self.englishNegativeCases { try runNoFixDecisionOnly(tc, algorithm: .appleNL) }
    }

}
