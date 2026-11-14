import Carbon.HIToolbox
import XCTest
@testable import PapugaKit

/// Uses the evaluator called by AutoFixController, real OS layouts, the default local scorer,
/// real system spelling, and shipped dictionaries. No predicted outcomes are mocked.
final class AutoFixTypingCorpusTests: XCTestCase {
    func test_correctWordsRemainProtectedWithTrailingPunctuation() throws {
        let uk = try source("com.apple.keylayout.Ukrainian-PC")
        let en = try source("com.apple.keylayout.US")
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: Self.checker,
                                             scorer: LanguageScorerFactory.make(.appleNL))
        for (from, to, words) in [(uk, en, ["одягу", "інші", "бути", "рух", "так", "Привіт", "вже"]),
                                  (en, uk, ["them", "fix", "too", "me"])] {
            for word in words {
                for token in [word, word + ",", word + ".", word + "?", word + "!", word + "))", "(\(word))"] {
                    let result = evaluator.evaluate(token, source: from, targets: [to], configuration: .init())
                    XCTAssertEqual(result.disposition, .sourceWord, "\(token): \(result.disposition)")
                }
            }
        }
    }

    func test_unsubstantiatedLayoutTyposDoNotProduceCompoundProposals() throws {
        let uk = try source("com.apple.keylayout.Ukrainian-PC")
        let en = try source("com.apple.keylayout.US")
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: Self.checker,
                                             scorer: LanguageScorerFactory.make(.appleNL))
        for (from, to, words) in [(uk, en, ["баксів)", "х-арду,", "чт", "бекенді", "тетси"]),
                                  (en, uk, ["hono", "mvp", "qr", "->", "opps", "i;ve"])] {
            for word in words {
                let result = evaluator.evaluate(word, source: from, targets: [to], configuration: .init(threshold: 0.5))
                if case .suggestCompound = result.disposition {
                    XCTFail("No independent layout evidence: \(word) → \(result.disposition)")
                }
                XCTAssertNil(result.replacement, word)
            }
        }
    }

    func test_automaticTargetMustReadAsWord() {
        let checker = HybridSpellChecker(indexes: DictionaryBuilder.build(base: [
            "en": [("tv", 1000)], "uk": [("ще", 9000), ("ну", 9000)]
        ], learned: [:]))
        func plausible(_ word: String, _ language: String) -> Bool {
            AutoFixWordEvaluator.isPlausibleAutomaticTarget(word, language: language, spellChecker: checker)
        }
        // Field false fixes: `вп → dg`, `нєа, → y'f,`, `бре → ,ht`.
        XCTAssertFalse(plausible("dg", "en"))
        XCTAssertFalse(plausible("y'f,", "en"))
        XCTAssertFalse(plausible(",ht", "en"))
        XCTAssertTrue(plausible("tv", "en"))
        XCTAssertTrue(plausible("i've", "en"))
        XCTAssertTrue(plausible("роблю)", "uk"))
        XCTAssertFalse(plausible("gktqhfqn", "en"))
    }

    func test_undictionariedLayoutSlipNeedsNoiseSourceAndWordLikeTarget() {
        func slip(_ source: String, _ candidate: String, _ original: Double, _ mapped: Double) -> Bool {
            AutoFixWordEvaluator.isUndictionariedLayoutSlip(source: source, candidate: candidate,
                scoreOriginal: original, scoreCandidate: mapped)
        }
        // Slang in no dictionary, typed in the wrong layout.
        XCTAssertTrue(slip("jycfqn", "онсайт", 0.01, 0.07))
        XCTAssertTrue(slip("pfctnfgktyj", "засетаплено", 0.00, 0.14))
        // No vowel at all: noise whatever the scores say.
        XCTAssertTrue(slip("gsczk", "пісял", 0.00, 0.01))
        // Correctly typed translit slang must stay.
        XCTAssertFalse(slip("афтер", "fanth", 0.048, 0.172))
        // Mapped text is not word-shaped, too short, or no better than the source.
        XCTAssertFalse(slip("nginx", "тпштч", 0.01, 0.20))
        XCTAssertFalse(slip("yfc", "нас", 0.00, 0.90))
        XCTAssertFalse(slip("yffqce", "наайсу", 0.02, 0.03))
    }

    func test_shortSourceWordMappingToCommonTargetWordIsAmbiguous() {
        let checker = HybridSpellChecker(indexes: DictionaryBuilder.build(base: [
            "uk": [("ще", 9000), ("ну", 9000)]
        ], learned: [:]))
        func ambiguous(_ word: String, _ candidate: String) -> Bool {
            AutoFixWordEvaluator.isAmbiguousShortSourceWord(word, candidate: candidate,
                targetLanguage: "uk", spellChecker: checker)
        }
        XCTAssertTrue(ambiguous("ot", "ще"))
        XCTAssertTrue(ambiguous("ye", "ну"))
        // Not a common target word, too long, or carrying punctuation: still a contradiction.
        XCTAssertFalse(ambiguous("ok", "щл"))
        XCTAssertFalse(ambiguous("them", "еруь"))
        XCTAssertFalse(ambiguous("ot,", "щеб"))
    }

    func test_physicalPunctuationKeysStillConvertAndLiteralEdgesSurvive() throws {
        let en = try source("com.apple.keylayout.US")
        let uk = try source("com.apple.keylayout.Ukrainian-PC")
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: Self.checker,
                                             scorer: LanguageScorerFactory.make(.appleNL))
        for (input, expected) in [("nt;", "теж"), ("levf.", "думаю"), (",hfnb", "брати"),
                                  ("ghbdsn!", "привіт!"), ("(ghbdsn)", "(привіт)"), ("ghbdsn))", "привіт))")] {
            let result = evaluator.evaluate(input, source: en, targets: [uk], configuration: .init())
            if input == "nt;" {
                // те and теж are both real words: keep the existing suggestion path.
                XCTAssertEqual(result.selection?.best.candidate, expected)
                XCTAssertTrue(result.disposition == .suggestLayout || result.disposition == .replace, "\(result.disposition)")
            } else {
                XCTAssertEqual(result.replacement?.candidate, expected, "\(input): \(result.disposition)")
            }
        }
    }

    func test_manualPhraseEvidenceImprovesRankingWithoutChangingCorrectText() throws {
        let model = PersonalLayoutModel.shared
        model.replaceHistory([])
        defer { model.replaceHistory([]) }
        let from = try source("com.apple.keylayout.US")
        let to = try source("com.apple.keylayout.Ukrainian-PC")
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: Self.checker,
                                             scorer: LanguageScorerFactory.make(.appleNL))
        let before = try XCTUnwrap(evaluator.evaluate("lfdfq", source: from, targets: [to], configuration: .init()).selection)
        model.replaceHistory((0..<3).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from.id, targetLayoutID: to.id, bundleID: "test.editor", verificationSucceeded: true)
        })
        let after = try XCTUnwrap(evaluator.evaluate("lfdfq", source: from, targets: [to], configuration: .init()).selection)
        XCTAssertGreaterThan(after.best.scoreCandidate, before.best.scoreCandidate)
        XCTAssertEqual(evaluator.evaluate("hello", source: from, targets: [to], configuration: .init()).disposition, .sourceWord)
    }

    func test_sameScriptLayoutUsesVerifiedDictionaryEvidence() throws {
        let from = try source("com.apple.keylayout.US")
        let to = try source("com.apple.keylayout.French")
        let checker = HybridSpellChecker(indexes: DictionaryBuilder.build(base: [
            "en": [("hello", 1000)], "fr": [("avec", 1000)]
        ], learned: [:]))
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: checker,
                                             scorer: LanguageScorerFactory.make(.appleNL))
        // Like cross-script evidence, exact layout/dictionary evidence does not
        // require the language identifier to report an impossible margin of 1.
        let result = evaluator.evaluate("qvec", source: from, targets: [to], configuration: .init(threshold: 1))
        XCTAssertEqual(result.replacement?.candidate, "avec", "\(result.disposition)")
        XCTAssertNil(evaluator.evaluate("hello", source: from, targets: [to], configuration: .init()).replacement)
    }

    func test_verifiedContextResolvesLayoutAmbiguityAndUndoRetractsIt() throws {
        let model = PersonalLayoutModel.shared
        model.replaceHistory([])
        defer { model.replaceHistory([]) }
        let from = try source("com.apple.keylayout.US")
        let uk = try source("com.apple.keylayout.Ukrainian-PC")
        let ru = try source("com.apple.keylayout.Russian")
        let checker = HybridSpellChecker(indexes: DictionaryBuilder.build(base: [
            "uk": [("сір", 1000)], "ru": [("сыр", 1000)]
        ], learned: [:]))
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: checker,
                                             scorer: LanguageScorerFactory.make(.appleNL))
        func evaluate(_ context: String?) -> AutoFixWordEvaluation {
            evaluator.evaluate("csh", source: from, targets: [ru, uk], configuration: .init(), previousWord: context)
        }
        XCTAssertEqual(evaluate("ghbdsn").disposition, .suggestLayout)
        var history = (0..<3).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "ghbdsn csh ", converted: "привіт сір ",
                sourceLayoutID: from.id, targetLayoutID: uk.id, verificationSucceeded: true)
        }
        model.replaceHistory(history)
        XCTAssertEqual(evaluate("ghbdsn").replacement?.targetID, uk.id)
        XCTAssertEqual(evaluate(nil).disposition, .suggestLayout)
        XCTAssertEqual(evaluate("different").disposition, .suggestLayout)
        let competing = (3..<6).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "ghbdsn csh ", converted: "привыт сыр ",
                sourceLayoutID: from.id, targetLayoutID: ru.id, verificationSucceeded: true)
        }
        model.replaceHistory(history + competing)
        XCTAssertEqual(evaluate("ghbdsn").disposition, .suggestLayout)
        model.replaceHistory(history)
        history.append(ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: 300000),
            kind: .autoFixUndone, original: "csh", converted: "сір", sourceLayoutID: from.id))
        model.replaceHistory(history)
        XCTAssertEqual(evaluate("ghbdsn").disposition, .suggestLayout)
    }

    private struct Case: Decodable {
        let id: String
        let category: String
        let keys: String
        let expectedText: String
        let expectedLayout: String
    }
    private func source(_ id: String) throws -> InputSourceInfo {
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID!: id] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        return InputSourceInfo(id: id, name: id, source: try XCTUnwrap(list.first, "Required test layout missing: \(id)"))
    }
    private static let checker = HybridSpellChecker(indexes: DictionaryBuilder.build(base: [
            "uk": DictionaryBuilder.loadBundledBase(language: "uk"),
            "en": DictionaryBuilder.loadBundledBase(language: "en")
        ], learned: [:]))

    private func check(_ category: String) throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/typing/corpus.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: path)).filter { $0.category == category }
        XCTAssertFalse(cases.isEmpty, "A missing corpus category must not turn green")
        let from = try source("com.apple.keylayout.US")
        let to = try source("com.apple.keylayout.Ukrainian-PC")
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: Self.checker, scorer: LanguageScorerFactory.make(.appleNL))
        for tc in cases {
            XCTContext.runActivity(named: "\(tc.id): \(tc.keys) → \(tc.expectedText)") { _ in
                let actual = evaluator.evaluate(String(tc.keys.dropLast()), source: from, targets: [to], configuration: .init())
                if tc.expectedLayout == from.id {
                    XCTAssertNil(actual.replacement, "\(tc.id): must preserve intentional input; got \(actual.disposition)")
                } else {
                    XCTAssertEqual(actual.replacement?.candidate, String(tc.expectedText.dropLast()),
                        "\(tc.id): \(actual.disposition); scores \(actual.scoreOriginal)/\(actual.effectiveScore)")
                    XCTAssertEqual(actual.replacement?.targetID, tc.expectedLayout, tc.id)
                    if let replacement = actual.replacement {
                        XCTAssertTrue(AutoFixDecision.shouldBypassLayoutIncidentGrace(
                            scoreCandidate: replacement.scoreCandidate, hasVerifiedLayoutWord: true),
                            "\(tc.id): an approved dictionary-backed correction must not wait for more words")
                    }
                }
            }
        }
    }
    func test_unverifiedThirdLayoutDoesNotHideVerifiedUkrainianWord() throws {
        let from = try source("com.apple.keylayout.US")
        let ukrainian = try source("com.apple.keylayout.Ukrainian-PC")
        let russian = try source("com.apple.keylayout.Russian")
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: Self.checker, scorer: LanguageScorerFactory.make(.appleNL))
        let result = evaluator.evaluate("ghbdsn", source: from, targets: [russian, ukrainian], configuration: .init())
        XCTAssertEqual(result.replacement?.candidate, "привіт", "\(result.disposition)")
        XCTAssertEqual(result.replacement?.targetID, ukrainian.id)
    }

    func test_learnedAbbreviationIsNotReplacedByFrequentUkrainianWord() throws {
        let from = try source("com.apple.keylayout.US")
        let to = try source("com.apple.keylayout.Ukrainian-PC")
        let checker = HybridSpellChecker(indexes: DictionaryBuilder.build(base: [
            "uk": DictionaryBuilder.loadBundledBase(language: "uk"),
            "en": DictionaryBuilder.loadBundledBase(language: "en")
        ], learned: [:]), learnedKnown: ["en": ["yt", "vtys", "wt"]])
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: checker, scorer: LanguageScorerFactory.make(.appleNL))
        for word in ["yt", "vtys", "wt"] {
            let result = evaluator.evaluate(word, source: from, targets: [to], configuration: .init())
            XCTAssertEqual(result.disposition, .sourceWord, word)
            XCTAssertNil(result.replacement, word)
        }
    }

    func test_positiveCorpusTargetsAreExplicitlyAttested() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/typing/corpus.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: path))
            .filter { $0.category != "continuous" && $0.expectedLayout == "com.apple.keylayout.Ukrainian-PC" }

        for tc in cases {
            let rendered = String(tc.expectedText.dropLast())
            let core = BufferedToken(rawText: rendered, keyCodes: []).core
            XCTAssertTrue(Self.checker.isExplicitlyKnown(core, language: "uk"), "\(tc.id): \(core)")
        }
    }

    func test_punctuationIsPreserved() throws { try check("punctuation") }
    func test_englishTyposDoNotBecomeUkrainian() throws { try check("typo") }
    func test_commonWords() throws { try check("common") }
    func test_shortWords() throws { try check("short") }
    func test_longWords() throws { try check("long") }
    func test_hyphenatedWords() throws { try check("hyphen") }
    func test_apostropheWords() throws { try check("apostrophe") }
    func test_capitalizedWords() throws { try check("capitalized") }
    func test_intentionalEnglishIsNotReplaced() throws { try check("negative") }
    func test_codeAddressesNumbersAndAmbiguousWordsAreNotReplaced() throws { try check("protected") }
}
