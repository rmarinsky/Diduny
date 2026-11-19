import XCTest
@testable import PapugaKit

final class AutoFixDecisionObservationTests: XCTestCase {
    func test_reviewableSignalsKeepActionsAndBalancedNearMissesOnly() {
        let replacement = makeObservation(
            outcome: .replaced,
            originalScore: 0.10,
            effectiveCandidateScore: 0.70,
            threshold: 0.35,
            signalKind: .replacement
        )
        let nearMiss = makeObservation(
            outcome: .skipped,
            originalScore: 0.20,
            effectiveCandidateScore: 0.34,
            threshold: 0.35,
            proposalWindow: 0.22,
            signalKind: .nearThreshold
        )
        let farBelow = makeObservation(
            outcome: .skipped,
            originalScore: 1.0,
            effectiveCandidateScore: 0,
            threshold: 0.35,
            proposalWindow: 0.22
        )

        XCTAssertTrue(replacement.isReviewableSignal)
        XCTAssertTrue(nearMiss.isReviewableSignal)
        XCTAssertTrue(nearMiss.isInsideProposalWindow)
        XCTAssertFalse(farBelow.isReviewableSignal)
        XCTAssertFalse(farBelow.isInsideProposalWindow)
    }

    func test_historyTableShowsOnlyProposalsAndCompletedReplacementsWithARealCandidate() {
        let replacement = makeObservation(
            outcome: .replaced,
            originalScore: 0.10,
            effectiveCandidateScore: 0.70,
            threshold: 0.35
        )
        let proposal = makeObservation(
            outcome: .proposed,
            originalScore: 0.10,
            effectiveCandidateScore: 0.30,
            threshold: 0.35
        )
        let skipped = makeObservation(
            outcome: .skipped,
            originalScore: 0.10,
            effectiveCandidateScore: 0.30,
            threshold: 0.35,
            signalKind: .nearThreshold
        )
        let missingCandidate = makeObservation(
            outcome: .proposed,
            originalScore: 0.10,
            effectiveCandidateScore: 0.30,
            threshold: 0.35,
            selectedCandidate: nil
        )
        let unchangedCandidate = makeObservation(
            outcome: .proposed,
            originalScore: 0.10,
            effectiveCandidateScore: 0.30,
            threshold: 0.35,
            selectedCandidate: "ghbdtn"
        )

        XCTAssertTrue(replacement.isDisplayableHistorySignal)
        XCTAssertTrue(proposal.isDisplayableHistorySignal)
        XCTAssertFalse(skipped.isDisplayableHistorySignal)
        XCTAssertFalse(missingCandidate.isDisplayableHistorySignal)
        XCTAssertFalse(unchangedCandidate.isDisplayableHistorySignal)
    }

    func test_nearThresholdRequiresPositiveMarginInsideConfiguredWindow() {
        let inside = makeObservation(
            outcome: .skipped,
            originalScore: 0.20,
            effectiveCandidateScore: 0.34,
            threshold: 0.35,
            proposalWindow: 0.22
        )
        let outside = makeObservation(
            outcome: .skipped,
            originalScore: 0.20,
            effectiveCandidateScore: 0.32,
            threshold: 0.35,
            proposalWindow: 0.12
        )
        let negativeMargin = makeObservation(
            outcome: .skipped,
            originalScore: 0.80,
            effectiveCandidateScore: 0.70,
            threshold: 0.35,
            proposalWindow: 0.50
        )

        XCTAssertTrue(inside.isInsideProposalWindow)
        XCTAssertFalse(outside.isInsideProposalWindow)
        XCTAssertFalse(negativeMargin.isInsideProposalWindow)
    }

    func test_validSourceLanguageWordNeverBecomesAReviewableNearThresholdSignal() {
        let validEnglishWord = makeObservation(
            outcome: .skipped,
            originalScore: 0.20,
            effectiveCandidateScore: 0.34,
            threshold: 0.35,
            proposalWindow: 0.22,
            reason: AutoFixSkipReason.originalIsRealWord.rawValue
        )

        XCTAssertTrue(validEnglishWord.isInsideProposalWindow)
        XCTAssertNil(validEnglishWord.resolvedSignalKind)
        XCTAssertFalse(validEnglishWord.isReviewableSignal)
    }

    func test_balancedProposalWindowIncludesExactBoundaryAndRejectsOutsideIt() {
        let exactBoundary = makeObservation(
            outcome: .skipped,
            originalScore: 0,
            effectiveCandidateScore: 0.13,
            threshold: 0.35,
            proposalWindow: 0.22
        )
        let justOutside = makeObservation(
            outcome: .skipped,
            originalScore: 0,
            effectiveCandidateScore: 0.129,
            threshold: 0.35,
            proposalWindow: 0.22
        )

        XCTAssertTrue(exactBoundary.isInsideProposalWindow)
        XCTAssertFalse(justOutside.isInsideProposalWindow)
    }

    func test_incidentTokensStayAggregateOnlyEvenWhenTheirMarginIsNearThreshold() {
        let token = makeObservation(
            outcome: .skipped,
            originalScore: 0.20,
            effectiveCandidateScore: 0.34,
            threshold: 0.35,
            proposalWindow: 0.22,
            aggregateOnly: true
        )

        XCTAssertTrue(token.isInsideProposalWindow)
        XCTAssertFalse(token.isReviewableSignal)
    }

    func test_marginAndThresholdGapDescribeTheActualDecision() {
        let observation = makeObservation(
            outcome: .skipped,
            originalScore: 0.22,
            effectiveCandidateScore: 0.48,
            threshold: 0.30
        )

        XCTAssertEqual(observation.margin ?? .nan, 0.26, accuracy: 0.0001)
        XCTAssertEqual(observation.thresholdGap ?? .nan, -0.04, accuracy: 0.0001)
        XCTAssertFalse(observation.clearedReplacementThreshold)
    }

    func test_spellingSignalResolvesConfidenceWithoutLayoutMargin() throws {
        let observation = makeObservation(
            outcome: .proposed,
            originalScore: nil,
            effectiveCandidateScore: nil,
            threshold: 0.35,
            selectedCandidate: "everything",
            source: "everithing",
            candidateOrigin: .spelling
        )

        XCTAssertNil(observation.margin)
        XCTAssertEqual(observation.resolvedConfidence ?? .nan, 0.90, accuracy: 0.0001)

        let decoded = try JSONDecoder().decode(
            AutoFixDecisionObservation.self,
            from: JSONEncoder().encode(observation)
        )
        XCTAssertEqual(decoded.resolvedConfidence ?? .nan, 0.90, accuracy: 0.0001)
    }

    func test_summarySeparatesReplacedProposedAndSkippedCalculations() {
        let entries = [
            makeObservation(outcome: .replaced, originalScore: 0.10, effectiveCandidateScore: 0.70, threshold: 0.30),
            makeObservation(outcome: .proposed, originalScore: 0.20, effectiveCandidateScore: 0.45, threshold: 0.30),
            makeObservation(outcome: .skipped, originalScore: 0.30, effectiveCandidateScore: 0.42, threshold: 0.30),
            makeObservation(outcome: .skipped, originalScore: nil, effectiveCandidateScore: nil, threshold: 0.30)
        ]

        let summary = AutoFixDecisionSummary(entries: entries)

        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.calculated, 3)
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertEqual(summary.proposed, 1)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(summary.belowThreshold, 2)
        XCTAssertEqual(summary.averageBelowThresholdGap ?? .nan, -0.115, accuracy: 0.0001)
    }

    @MainActor
    func test_rangeClearRewritesAllPersistedRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AutoFixDecisionHistoryStore(
            testFileURL: directory.appendingPathComponent("decision-history.jsonl")
        )
        store.isEnabled = true
        store.retention = .forever
        let first = makeObservation(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1), outcome: .skipped,
            originalScore: 0.2, effectiveCandidateScore: 0.3, threshold: 0.3,
            signalKind: .nearThreshold
        )
        let second = makeObservation(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 2), outcome: .skipped,
            originalScore: 0.2, effectiveCandidateScore: 0.3, threshold: 0.3,
            signalKind: .nearThreshold
        )
        let third = makeObservation(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 3), outcome: .skipped,
            originalScore: 0.2, effectiveCandidateScore: 0.3, threshold: 0.3,
            signalKind: .nearThreshold
        )
        let aggregateOnly = makeObservation(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 4), outcome: .skipped,
            originalScore: 1, effectiveCandidateScore: 0, threshold: 0.3,
            aggregateOnly: true
        )

        store.record(first)
        store.record(second)
        store.record(third)
        store.record(aggregateOnly)
        store.waitForPendingWritesForTesting()
        XCTAssertEqual(store.entries.map(\.id), [third.id, second.id, first.id])
        XCTAssertEqual(store.aggregates.reduce(0) { $0 + $1.count }, 1)

        store.clear(
            where: { $0.id == third.id },
            aggregateWhere: { _ in true }
        )
        store.waitForPendingWritesForTesting()

        XCTAssertEqual(store.loadEntriesSync().map(\.id), [second.id, first.id])
        XCTAssertTrue(store.aggregates.isEmpty)
    }

    @MainActor
    func test_storePersistsEveryCandidateScore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("decision-history.jsonl")
        let store = AutoFixDecisionHistoryStore(testFileURL: fileURL)
        store.isEnabled = true
        store.retention = .forever
        let entry = makeObservation(
            outcome: .proposed,
            originalScore: 0.18,
            effectiveCandidateScore: 0.44,
            threshold: 0.30,
            candidates: [
                AutoFixScoredCandidate(text: "привіт", targetLayoutID: "uk", language: "uk", score: 0.44),
                AutoFixScoredCandidate(text: "привет", targetLayoutID: "ru", language: "ru", score: 0.41)
            ]
        )

        store.record(entry)
        store.waitForPendingWritesForTesting()

        let loaded = store.loadEntriesSync()
        XCTAssertEqual(loaded, [entry])
        XCTAssertEqual(loaded.first?.candidates.map(\.score), [0.44, 0.41])
    }

    @MainActor
    func test_storePersistsSignalsAndAggregatesObviousChecksWithoutText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AutoFixDecisionHistoryStore(
            testFileURL: directory.appendingPathComponent("decision-history.jsonl"),
            testAggregateFileURL: directory.appendingPathComponent("decision-aggregates.json")
        )
        store.isEnabled = true
        store.retention = .forever
        let signal = makeObservation(
            outcome: .proposed,
            originalScore: 0.1,
            effectiveCandidateScore: 0.3,
            threshold: 0.35,
            signalKind: .proposal
        )
        let obvious = makeObservation(
            outcome: .skipped,
            originalScore: 1,
            effectiveCandidateScore: 0,
            threshold: 0.35,
            reason: AutoFixSkipReason.originalIsRealWord.rawValue
        )

        store.record(signal)
        store.record(obvious)
        store.waitForPendingWritesForTesting()

        XCTAssertEqual(store.entries, [signal])
        XCTAssertEqual(store.loadEntriesSync(), [signal])
        XCTAssertEqual(store.aggregates.map(\.count).reduce(0, +), 1)

        let aggregateData = try Data(contentsOf: directory.appendingPathComponent("decision-aggregates.json"))
        let aggregateJSON = try XCTUnwrap(String(data: aggregateData, encoding: .utf8))
        XCTAssertFalse(aggregateJSON.contains(obvious.source))
        XCTAssertFalse(aggregateJSON.contains(obvious.selectedCandidate ?? ""))
        XCTAssertFalse(aggregateJSON.contains(obvious.bundleID ?? ""))
    }

    @MainActor
    func test_storeRecordsNothingForBlockedContext() throws {

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AutoFixDecisionHistoryStore(
            testFileURL: directory.appendingPathComponent("decision-history.jsonl"),
            testAggregateFileURL: directory.appendingPathComponent("decision-aggregates.json")
        )
        store.isEnabled = true
        let blocked = makeObservation(
            outcome: .skipped,
            originalScore: nil,
            effectiveCandidateScore: nil,
            threshold: 0.35,
            reason: AutoFixSkipReason.blocklist.rawValue
        )

        store.record(blocked)
        store.waitForPendingWritesForTesting()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.aggregates.isEmpty)
    }

    @MainActor
    func test_bootstrapPreservesAggregateRecordedWhileDiskSnapshotIsLoading() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let decisionURL = directory.appendingPathComponent("decision-history.jsonl")
        let aggregateURL = directory.appendingPathComponent("decision-aggregates.json")
        let seedStore = AutoFixDecisionHistoryStore(
            testFileURL: decisionURL,
            testAggregateFileURL: aggregateURL
        )
        seedStore.isEnabled = true
        seedStore.retention = .forever
        seedStore.record(makeObservation(
            outcome: .skipped,
            originalScore: 1,
            effectiveCandidateScore: 0,
            threshold: 0.35,
            aggregateOnly: true
        ))
        seedStore.waitForPendingWritesForTesting()

        let reloadedStore = AutoFixDecisionHistoryStore(
            testFileURL: decisionURL,
            testAggregateFileURL: aggregateURL
        )
        reloadedStore.isEnabled = true
        reloadedStore.retention = .forever
        reloadedStore.bootstrap()
        reloadedStore.record(makeObservation(
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            outcome: .skipped,
            originalScore: 1,
            effectiveCandidateScore: 0,
            threshold: 0.35,
            aggregateOnly: true
        ))
        reloadedStore.waitForPendingWritesForTesting()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(reloadedStore.aggregates.reduce(0) { $0 + $1.count }, 2)
    }

    @MainActor
    func test_bootstrapBoundsAnonymousAggregateCountAndFileSizeWhenRetentionIsForever() async throws {

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let decisionURL = directory.appendingPathComponent("decision-history.jsonl")
        let aggregateURL = directory.appendingPathComponent("decision-aggregates.json")
        let observations = (0..<12).map { index in
            makeObservation(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 - Double(index * 86_400)),
                outcome: .skipped,
                originalScore: 1,
                effectiveCandidateScore: 0,
                threshold: 0.35,
                reason: "aggregate-\(index)",
                aggregateOnly: true
            )
        }
        let aggregates = observations.map { AutoFixDecisionAggregate(observation: $0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(aggregates).write(to: aggregateURL)

        let store = AutoFixDecisionHistoryStore(
            testFileURL: decisionURL,
            testAggregateFileURL: aggregateURL,
            aggregateMemoryCap: 5,
            aggregateFileSizeCap: 700
        )
        store.retention = .forever
        store.bootstrap()
        store.waitForPendingWritesForTesting()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertLessThanOrEqual(store.aggregates.count, 5)
        let persistedData = try Data(contentsOf: aggregateURL)
        XCTAssertLessThanOrEqual(persistedData.count, 700)
        XCTAssertEqual(store.aggregates, store.aggregates.sorted { $0.day > $1.day })
    }

    private func makeObservation(
        id: UUID = UUID(),
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        outcome: AutoFixDecisionObservation.Outcome,
        originalScore: Double?,
        effectiveCandidateScore: Double?,
        threshold: Double,
        proposalWindow: Double = 0.12,
        candidates: [AutoFixScoredCandidate] = [],
        reason: String? = nil,
        signalKind: AutoFixDecisionSignalKind? = nil,
        aggregateOnly: Bool = false,
        selectedCandidate: String? = "привіт",
        source: String = "ghbdtn",
        candidateOrigin: AutoFixDecisionCandidateOrigin? = nil,
        confidence: Double? = nil
    ) -> AutoFixDecisionObservation {
        AutoFixDecisionObservation(
            id: id,
            timestamp: timestamp,
            source: source,
            selectedCandidate: selectedCandidate,
            candidates: candidates,
            originalScore: originalScore,
            rawCandidateScore: effectiveCandidateScore,
            effectiveCandidateScore: effectiveCandidateScore,
            confidence: confidence,
            threshold: threshold,
            proposalWindow: proposalWindow,
            candidateSeparation: 0.15,
            minimumWordLength: 2,
            algorithm: .appleNL,
            outcome: outcome,
            reason: reason ?? (outcome == .skipped ? AutoFixSkipReason.belowThreshold.rawValue : nil),
            scope: .word,
            sourceLayoutID: "en",
            targetLayoutID: "uk",
            sourceLanguage: "en",
            targetLanguage: "uk",
            bundleID: "com.apple.TextEdit",
            signalKind: signalKind,
            candidateOrigin: candidateOrigin,
            aggregateOnly: aggregateOnly
        )
    }
}
