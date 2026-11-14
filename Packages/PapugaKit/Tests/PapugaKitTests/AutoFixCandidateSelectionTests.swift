import Carbon.HIToolbox
import XCTest
@testable import PapugaKit

final class AutoFixCandidateSelectionTests: XCTestCase {
    // MARK: - Pure selection logic

    private func candidate(_ id: String, _ score: Double, lang: String = "uk", text: String = "x") -> AutoFixTargetCandidate {
        AutoFixTargetCandidate(targetID: id, targetLang: lang, candidate: text, scoreCandidate: score)
    }

    func test_select_returnsNilForEmptyCandidates() {
        XCTAssertNil(AutoFixCandidateGenerator.select(
            candidates: [],
            scoreOriginal: 0.1,
            threshold: 0.3,
            separation: 0.15
        ))
    }

    func test_select_picksHighestMargin() {
        let selection = AutoFixCandidateGenerator.select(
            candidates: [candidate("a", 0.4), candidate("b", 0.9), candidate("c", 0.5)],
            scoreOriginal: 0.1,
            threshold: 0.3,
            separation: 0.15
        )
        XCTAssertEqual(selection?.best.targetID, "b")
        XCTAssertEqual(selection?.runnerUp?.targetID, "c")
        XCTAssertEqual(selection?.isAmbiguous, false)
    }

    func test_select_flagsAmbiguousWhenTopTwoAreClose() {
        let selection = AutoFixCandidateGenerator.select(
            candidates: [candidate("uk", 0.90), candidate("ru", 0.85)],
            scoreOriginal: 0.1,
            threshold: 0.3,
            separation: 0.15
        )
        XCTAssertEqual(selection?.best.targetID, "uk")
        XCTAssertTrue(selection?.isAmbiguous == true)
    }

    func test_select_zeroSeparationNeverAmbiguous() {
        let selection = AutoFixCandidateGenerator.select(
            candidates: [candidate("uk", 0.90), candidate("ru", 0.89)],
            scoreOriginal: 0.1,
            threshold: 0.3,
            separation: 0.0
        )
        XCTAssertEqual(selection?.isAmbiguous, false)
        XCTAssertEqual(selection?.best.targetID, "uk")
    }

    func test_select_notAmbiguousWhenRunnerUpBelowThreshold() {
        // Top passes threshold (margin 0.30), runner-up fails (margin 0.16) even though their
        // absolute scores are within the separation window.
        let selection = AutoFixCandidateGenerator.select(
            candidates: [candidate("a", 0.40), candidate("b", 0.26)],
            scoreOriginal: 0.10,
            threshold: 0.30,
            separation: 0.15
        )
        XCTAssertEqual(selection?.best.targetID, "a")
        XCTAssertEqual(selection?.isAmbiguous, false)
    }

    func test_select_tieBreakIsStableByInputOrder() {
        let selection = AutoFixCandidateGenerator.select(
            candidates: [candidate("first", 0.8), candidate("second", 0.8)],
            scoreOriginal: 0.1,
            threshold: 0.3,
            separation: 0.15
        )
        XCTAssertEqual(selection?.best.targetID, "first")
    }

    // MARK: - Real-layout integration

    private func source(forID id: String) throws -> TISInputSource {
        let conditions = [kTISPropertyInputSourceID!: id as CFString] as CFDictionary
        guard let list = TISCreateInputSourceList(conditions, true)?.takeRetainedValue() as? [TISInputSource],
              let s = list.first else {
            throw XCTSkip("Input source \(id) not present on this Mac.")
        }
        return s
    }

    /// `ghbdsn` typed on US should resolve to the Ukrainian target (`привіт`), never the German one
    /// — German is identical under the position mapping (g/h/b/d/s/n are unchanged) and must be
    /// dropped, so the multi-target search cannot pick a wrong-direction conversion.
    func test_ghbdsn_resolvesToUkrainian_notGerman() throws {
        let currentID = "com.apple.keylayout.US"
        let targets = ["com.apple.keylayout.German", "com.apple.keylayout.Ukrainian-PC"]

        let mapper = CharacterMapper()
        mapper.buildMap(for: try source(forID: currentID), sourceID: currentID)

        let scorer = LanguageScorerFactory.make(.appleNL)
        let word = "ghbdsn"
        let scoreOriginal = scorer.score(word, expecting: AutoFixDecision.languageHintForLayoutID(currentID))

        var evaluated: [AutoFixTargetCandidate] = []
        for targetID in targets {
            mapper.buildMap(for: try source(forID: targetID), sourceID: targetID)
            let mapped = mapper.convert(text: word, fromSourceID: currentID, toSourceID: targetID)
            guard mapped != word else { continue }
            let lang = AutoFixDecision.languageHintForLayoutID(targetID)
            evaluated.append(AutoFixTargetCandidate(
                targetID: targetID,
                targetLang: lang,
                candidate: mapped,
                scoreCandidate: scorer.score(mapped, expecting: lang)
            ))
        }

        let selection = AutoFixCandidateGenerator.select(
            candidates: evaluated,
            scoreOriginal: scoreOriginal,
            threshold: 0.3,
            separation: 0.15
        )

        XCTAssertEqual(selection?.best.targetID, "com.apple.keylayout.Ukrainian-PC")
        XCTAssertEqual(selection?.best.candidate, "привіт")
    }
}
