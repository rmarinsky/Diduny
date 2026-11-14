import XCTest
@testable import PapugaKit

final class AutoFixProposalPolicyTests: XCTestCase {
    @MainActor
    func test_controllerPersistsThePresentedCandidateAndItsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("decisions.jsonl")
        let store = AutoFixDecisionHistoryStore(testFileURL: file)
        // Was `Defaults[.replacementHistoryEnabled] = true`; the store now holds that value itself.
        store.isEnabled = true
        let controller = AutoFixControllerHarness(directory: directory, decisionHistory: store).controller
        let proposal = makeProposal(kind: .compound, original: "ghbds", candidate: "привіт", scoreOriginal: 0.12, threshold: 0.5)
        controller.recordProposalPresentation(proposal)
        store.waitForPendingWritesForTesting()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observation = try decoder.decode(AutoFixDecisionObservation.self, from: Data(lines[0].utf8))
        XCTAssertEqual(observation.id, proposal.id)
        XCTAssertEqual(observation.selectedCandidate, "привіт")
        XCTAssertEqual(observation.proposalContext?.kind, "compound")
        XCTAssertEqual(observation.originalScore, 0.12)
        XCTAssertEqual(observation.threshold, 0.5)
        XCTAssertNil(observation.effectiveCandidateScore)
    }

    func test_presentedProposalRoundTripsTheActualCandidateAndSharedID() throws {
        for kind: AutoFixProposal.Kind in [.detected, .compound, .spelling, .customRule] {
            let proposal = makeProposal(kind: kind, original: "(ghbds!)", candidate: "(привіт!)")
            let observation = proposal.decisionObservation(proposalWindow: 0.35, candidateSeparation: 0.15, minimumWordLength: 2)
            let data = try JSONEncoder().encode(observation)
            let restored = try JSONDecoder().decode(AutoFixDecisionObservation.self, from: data)
            XCTAssertEqual(restored.id, proposal.id)
            XCTAssertEqual(restored.selectedCandidate, "(привіт!)")
            XCTAssertEqual(restored.source, "(ghbds!)")
            XCTAssertEqual(restored.proposalContext?.sourceCore, "ghbds")
            XCTAssertEqual(restored.proposalContext?.leadingPunctuation, "(")
            XCTAssertEqual(restored.proposalContext?.trailingPunctuation, "!)")
            XCTAssertEqual(restored.proposalContext?.kind, String(describing: kind))
            XCTAssertEqual(restored.outcome, .proposed)
            if kind == .compound { XCTAssertNil(restored.effectiveCandidateScore) }
        }
    }

    func test_legacyObservationsWithoutProposalContextStillDecode() throws {
        let proposal = makeProposal(kind: .detected)
        let observation = proposal.decisionObservation(proposalWindow: 0.35, candidateSeparation: 0.15, minimumWordLength: 2)
        let data = try JSONEncoder().encode(observation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "proposalContext")
        let legacy = try JSONDecoder().decode(AutoFixDecisionObservation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.proposalContext)
        XCTAssertEqual(legacy.source, proposal.original)
        XCTAssertEqual(legacy.selectedCandidate, proposal.candidate)
    }

    func test_spellingProposalIsOccurrenceOnlyAndDoesNotSwitchLayout() {
        let proposal = makeProposal(kind: .spelling)

        XCTAssertFalse(proposal.createsRuleOnAcceptance)
        XCTAssertFalse(proposal.changesInputLayout)
        XCTAssertEqual(proposal.candidateOrigin, .spelling)
    }

    func test_detectedLayoutProposalKeepsExistingLayoutBehavior() {
        let proposal = makeProposal(kind: .detected)

        XCTAssertTrue(proposal.createsRuleOnAcceptance)
        XCTAssertTrue(proposal.changesInputLayout)
        XCTAssertEqual(proposal.candidateOrigin, .keyboardLayout)
    }

    func test_onlyNeverReplacePersistsAnIgnoreDecision() {
        XCTAssertFalse(AutoFixProposalOutcome.dismissed.shouldAddToAllowlist)
        XCTAssertFalse(AutoFixProposalOutcome.timedOut.shouldAddToAllowlist)
        XCTAssertFalse(AutoFixProposalOutcome.accepted.shouldAddToAllowlist)
        XCTAssertTrue(AutoFixProposalOutcome.neverReplace.shouldAddToAllowlist)
    }

    func test_dismissAndTimeoutOfferRecovery() {
        XCTAssertTrue(AutoFixProposalOutcome.dismissed.shouldOfferRecovery)
        XCTAssertTrue(AutoFixProposalOutcome.timedOut.shouldOfferRecovery)
        XCTAssertFalse(AutoFixProposalOutcome.accepted.shouldOfferRecovery)
        XCTAssertFalse(AutoFixProposalOutcome.neverReplace.shouldOfferRecovery)
    }

    func test_suggestsWhenCandidateIsBelowThresholdButInsideWindow() {
        XCTAssertTrue(AutoFixProposalPolicy.shouldSuggest(
            scoreOriginal: 0.30,
            scoreCandidate: 0.56,
            threshold: 0.30,
            window: 0.05
        ))
    }

    func test_doesNotSuggestWhenCandidateAlreadyMeetsAutoFixThreshold() {
        XCTAssertFalse(AutoFixProposalPolicy.shouldSuggest(
            scoreOriginal: 0.20,
            scoreCandidate: 0.55,
            threshold: 0.30,
            window: 0.12
        ))
    }

    func test_doesNotSuggestWhenCandidateIsTooFarFromThreshold() {
        XCTAssertFalse(AutoFixProposalPolicy.shouldSuggest(
            scoreOriginal: 0.30,
            scoreCandidate: 0.40,
            threshold: 0.30,
            window: 0.08
        ))
    }

    func test_doesNotSuggestWhenCandidateIsNotBetterThanOriginal() {
        XCTAssertFalse(AutoFixProposalPolicy.shouldSuggest(
            scoreOriginal: 0.50,
            scoreCandidate: 0.49,
            threshold: 0.30,
            window: 0.12
        ))
    }

    private func makeProposal(kind: AutoFixProposal.Kind, original: String = "важлво", candidate: String = "важливо", scoreOriginal: Double = 0, threshold: Double = 0.35) -> AutoFixProposal {
        AutoFixProposal(
            original: original,
            candidate: candidate,
            boundary: " ",
            fromLayoutID: "uk",
            targetLayoutID: kind == .spelling ? "uk" : "en",
            scoreOriginal: scoreOriginal,
            scoreCandidate: 1,
            threshold: threshold,
            algorithm: .appleNL,
            currentLang: "uk",
            targetLang: kind == .spelling ? "uk" : "en",
            bundleID: "com.apple.TextEdit",
            createdAt: 100,
            replacementAnchor: TextReplacementAnchor(
                targetPID: 10,
                bundleID: "com.apple.TextEdit",
                focusedElementIdentity: FocusedElementSignature.StableIdentity(
                    pid: 10,
                    role: "AXTextArea",
                    subrole: nil,
                    windowTitleHash: nil,
                    elementIdentifier: nil,
                    frameHash: nil
                ),
                sourceRange: AXTextRange(location: 0, length: 6),
                boundaryUTF16Length: 1,
                caretAfterBoundary: 7,
                expectedSource: "важлво",
                allowsKeyboardFallback: false
            ),
            kind: kind
        )
    }
}
