import XCTest
@testable import PapugaCore

final class LayoutIncidentTrackerTests: XCTestCase {
    // MARK: - Verdict: the margin of the joined run decides

    func test_highPhraseMarginReplacesRegardlessOfPerTokenStrength() {
        // "nj ljhtxs": weak + strong. The quorum verdict demanded three strong
        // tokens and replaced the strong half alone; phrase margin ~0.9 says
        // the whole run is a layout mistake.
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.09,
                scoreCandidate: 0.99,
                threshold: 0.5,
                proposalWindow: 0.22,
                hasContradiction: false
            ),
            .replace
        )
    }

    func test_blindReplacementRefusedOnceTypedPastWithoutCaret() {
        // Caret-less web editor: the live caret is after the word that ended the
        // run, so blind deletes from it would erase that word.
        XCTAssertFalse(LayoutIncidentTracker.allowsBlindReplacement(typedPastRun: true, boundaryCaret: nil))
        XCTAssertTrue(LayoutIncidentTracker.allowsBlindReplacement(typedPastRun: true, boundaryCaret: 12))
        XCTAssertTrue(LayoutIncidentTracker.allowsBlindReplacement(typedPastRun: false, boundaryCaret: nil))
    }

    func test_runWithoutStrongTokenNeverAutoReplaces() {
        // A run of only short/neutral words ("i", "nj") rests on the scorer
        // alone; a high margin earns a proposal, never a silent rewrite.
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.09,
                scoreCandidate: 0.99,
                threshold: 0.5,
                proposalWindow: 0.22,
                hasContradiction: false,
                hasStrongEvidence: false
            ),
            .propose
        )
    }

    func test_marginInsideProposalWindowProposes() {
        // A lone "nj" → "то": margin 0.44 with threshold 0.5, window 0.22.
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.16,
                scoreCandidate: 0.60,
                threshold: 0.5,
                proposalWindow: 0.22,
                hasContradiction: false
            ),
            .propose
        )
    }

    func test_marginBelowWindowDiscards() {
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.5,
                scoreCandidate: 0.6,
                threshold: 0.5,
                proposalWindow: 0.22,
                hasContradiction: false
            ),
            .discard
        )
    }

    func test_unanimousDictionarySupportProposesDespiteTheScorer() {
        // "іудутшву іудусещкі" → "selenide selectors": the scorer calls the
        // gibberish confident Ukrainian (negative margin), the dictionary calls
        // every candidate a real word — a proposal, never a replacement.
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.95,
                scoreCandidate: 0.5,
                threshold: 0.35,
                proposalWindow: 0.22,
                hasContradiction: false,
                hasUnanimousDictionarySupport: true
            ),
            .propose
        )
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.95,
                scoreCandidate: 0.5,
                threshold: 0.35,
                proposalWindow: 0.22,
                hasContradiction: true,
                hasUnanimousDictionarySupport: true
            ),
            .discard,
            "a contradiction in the judged run disarms the dictionary path too"
        )
    }

    func test_contradictionInsideTheJudgedRunNeverAutoReplaces() {
        // Safety valve: a run containing a word the user meant can be offered,
        // never silently mutated.
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.05,
                scoreCandidate: 0.99,
                threshold: 0.5,
                proposalWindow: 0.22,
                hasContradiction: true
            ),
            .propose
        )
    }

    // MARK: - Trimming: the correct word that ended the run stays untouched

    func test_trailingContradictionIsTrimmedFromTheJudgedRun() {
        var tracker = LayoutIncidentTracker()
        tracker.append(strongToken("vj;yf", "можна", caret: 6))
        tracker.append(strongToken("dbrjhbcnfnb", "використати", caret: 18))
        tracker.append(LayoutIncidentToken(
            original: "text",
            candidate: "еуые",
            boundary: " ",
            targetLayoutID: "uk",
            evidence: .contradiction,
            boundaryCaret: 23
        ))

        let judged = tracker.judgedTokens
        XCTAssertEqual(judged.count, 2)
        XCTAssertEqual(LayoutIncidentTracker.joinedBody(of: judged, \.original), "vj;yf dbrjhbcnfnb")
        XCTAssertEqual(LayoutIncidentTracker.joinedBody(of: judged, \.candidate), "можна використати")
        XCTAssertEqual(judged.last?.boundaryCaret, 18, "the anchor belongs to the last judged token")
        XCTAssertFalse(judged.contains { $0.evidence == .contradiction })
    }

    func test_runOfOnlyContradictionsJudgesAsEmpty() {
        var tracker = LayoutIncidentTracker()
        tracker.append(LayoutIncidentToken(
            original: "text",
            candidate: "еуые",
            boundary: " ",
            targetLayoutID: "uk",
            evidence: .contradiction
        ))
        XCTAssertTrue(tracker.judgedTokens.isEmpty)
    }

    // MARK: - Body assembly

    func test_neutralTokenIsPartOfTheJoinedRun() {
        var tracker = LayoutIncidentTracker()
        tracker.append(neutralToken("nj", "то"))
        tracker.append(strongToken("ljhtxs", "доречі"))

        XCTAssertEqual(tracker.originalBody, "nj ljhtxs")
        XCTAssertEqual(tracker.candidateBody, "то доречі")
        XCTAssertEqual(tracker.judgedTokens.count, 2)
    }

    func test_neutralEmojiAdjacencyIsPreserved() {
        var tracker = LayoutIncidentTracker()
        tracker.append(strongToken("vj;yf", "можна"))
        tracker.append(LayoutIncidentToken(
            original: "🙂",
            candidate: "🙂",
            boundary: " ",
            targetLayoutID: "uk",
            evidence: .neutral
        ))
        tracker.append(strongToken("dbrjhbcnfnb", "використати"))

        XCTAssertEqual(tracker.originalBody, "vj;yf 🙂 dbrjhbcnfnb")
        XCTAssertEqual(tracker.candidateBody, "можна 🙂 використати")
    }

    func test_sentenceBoundaryRecognisesSourceOrConvertedPunctuation() {
        var sourceTerminated = LayoutIncidentTracker()
        sourceTerminated.append(strongToken("wrong.", "словою"))

        var candidateTerminated = LayoutIncidentTracker()
        candidateTerminated.append(strongToken("цкщтпю", "wrong."))

        XCTAssertTrue(sourceTerminated.endsSentence)
        XCTAssertTrue(candidateTerminated.endsSentence)
    }

    func test_targetChangeBreaksIncidentInsteadOfMixingConversions() {
        var tracker = LayoutIncidentTracker()
        XCTAssertEqual(tracker.append(strongToken("one", "раз", target: "uk")), .accepted)
        XCTAssertEqual(tracker.append(strongToken("two", "два", target: "ru")), .targetChanged)
        XCTAssertEqual(tracker.wordCount, 1)
    }

    func test_safetyCapUsesWordsOrUTF16WithoutSplittingStoredText() {
        var tracker = LayoutIncidentTracker(maxWords: 30, maxUTF16Length: 300)
        for index in 0..<30 {
            let result = tracker.append(strongToken("w\(index)", "с\(index)"))
            XCTAssertEqual(result, index == 29 ? .reachedCap : .accepted)
        }

        XCTAssertEqual(tracker.wordCount, 30)
        XCTAssertTrue(tracker.isAtSafetyCap)

        var utf16Tracker = LayoutIncidentTracker(maxWords: 30, maxUTF16Length: 8)
        XCTAssertEqual(
            utf16Tracker.append(strongToken("👨‍👩‍👧‍👦", "родина")),
            .wouldExceedCap
        )
        XCTAssertTrue(utf16Tracker.isEmpty)
    }

    func test_overflowTokenIsNotAddedToAnExistingIncident() {
        var tracker = LayoutIncidentTracker(maxWords: 30, maxUTF16Length: 12)
        XCTAssertEqual(tracker.append(strongToken("abcd", "абвг")), .accepted)

        XCTAssertEqual(
            tracker.append(strongToken("0123456789", "0123456789")),
            .wouldExceedCap
        )
        XCTAssertEqual(tracker.originalBody, "abcd")
        XCTAssertEqual(tracker.candidateBody, "абвг")
    }

    func test_timerPromotesFastContinuationAndExpiresAtDefinedDeadlines() {
        var timer = LayoutIncidentTimerState()
        timer.armSingleWord(at: 10)

        XCTAssertTrue(timer.consumeFastContinuation(at: 10.29))
        XCTAssertNil(timer.takeDueAction(at: 11))

        timer.armSingleWord(at: 20)
        XCTAssertNil(timer.takeDueAction(at: 20.29))
        XCTAssertEqual(timer.takeDueAction(at: 20.3), .applySingleWord)

        timer.armIncidentIdle(at: 30)
        XCTAssertNil(timer.takeDueAction(at: 30.59))
        XCTAssertEqual(timer.takeDueAction(at: 30.6), .finalizeIncident)
    }

    func test_returnAndTabAreHardIncidentBoundaries() {
        XCTAssertTrue(LayoutIncidentTracker.isHardBoundary("\r"))
        XCTAssertTrue(LayoutIncidentTracker.isHardBoundary("\n"))
        XCTAssertTrue(LayoutIncidentTracker.isHardBoundary("\t"))
        XCTAssertFalse(LayoutIncidentTracker.isHardBoundary(" "))
    }

    private func strongToken(
        _ original: String,
        _ candidate: String,
        boundary: String = " ",
        target: String = "uk",
        caret: Int? = nil
    ) -> LayoutIncidentToken {
        LayoutIncidentToken(
            original: original,
            candidate: candidate,
            boundary: boundary,
            targetLayoutID: target,
            evidence: .strong,
            boundaryCaret: caret
        )
    }

    private func neutralToken(
        _ original: String,
        _ candidate: String,
        boundary: String = " "
    ) -> LayoutIncidentToken {
        LayoutIncidentToken(
            original: original,
            candidate: candidate,
            boundary: boundary,
            targetLayoutID: "uk",
            evidence: .neutral
        )
    }

    func testDictionaryBackedRunAppliesInsideProposalWindow() {
        func verdict(backed: Bool, contradiction: Bool = false, margin: Double = 0.32) -> LayoutIncidentDecision {
            LayoutIncidentTracker.runVerdict(scoreOriginal: 0, scoreCandidate: margin, threshold: 0.5,
                proposalWindow: 0.22, hasContradiction: contradiction, isDictionaryBackedRun: backed)
        }
        XCTAssertEqual(verdict(backed: true), .replace)
        XCTAssertEqual(verdict(backed: false), .propose)
        XCTAssertEqual(verdict(backed: true, contradiction: true), .propose)
        // Below the window the dictionary alone still never replaces.
        XCTAssertEqual(verdict(backed: true, margin: 0.1), .discard)
    }

    func testDictionaryBackedRunNeedsVerifiedWordAndOnlyShortFillers() {
        func token(_ original: String, _ evidence: LayoutIncidentToken.Evidence) -> LayoutIncidentToken {
            LayoutIncidentToken(original: original, candidate: original, boundary: " ",
                                targetLayoutID: "uk", evidence: evidence, boundaryCaret: nil)
        }
        XCTAssertTrue(LayoutIncidentTracker.isDictionaryBackedRun(
            [token("z", .neutral), token("ot", .neutral), token("hfp", .strong)]))
        // A long word the dictionary could not confirm keeps the run a proposal.
        XCTAssertFalse(LayoutIncidentTracker.isDictionaryBackedRun(
            [token("rhfot", .strong), token("ibdlie", .neutral)]))
        XCTAssertFalse(LayoutIncidentTracker.isDictionaryBackedRun([token("z", .neutral), token("s", .neutral)]))
        XCTAssertFalse(LayoutIncidentTracker.isDictionaryBackedRun([token("hfp", .strong)]))
        XCTAssertFalse(LayoutIncidentTracker.isDictionaryBackedRun(
            [token("hfp", .strong), token("the", .contradiction)]))
    }
}
