import XCTest
@testable import PapugaKit

final class TypingDecisionLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("decision-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func observation(
        _ outcome: AutoFixDecisionObservation.Outcome, source: String, to target: String?, at seconds: TimeInterval,
        origin: AutoFixDecisionCandidateOrigin? = nil, aggregateOnly: Bool = false
    ) -> AutoFixDecisionObservation {
        AutoFixDecisionObservation(
            timestamp: Date(timeIntervalSince1970: seconds), source: source, selectedCandidate: target,
            originalScore: 0.1, effectiveCandidateScore: 0.7, confidence: 0.9, threshold: 0.35,
            proposalWindow: 0.12, candidateSeparation: 0.15, minimumWordLength: 2, algorithm: .appleNL,
            outcome: outcome, scope: .word, bundleID: "com.apple.Notes", signalKind: .replacement,
            candidateOrigin: origin, aggregateOnly: aggregateOnly
        )
    }

    private func write<T: Encodable>(_ records: [T], to name: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func test_loadReturnsShownDecisionsAndUndosNewestFirstWithCounts() throws {
        try write([
            observation(.replaced, source: "ghbdtn", to: "привіт", at: 1_700_000_100),
            observation(.proposed, source: "teh", to: "the", at: 1_700_000_300, origin: .spelling),
            observation(.ruleApplied, source: "brb", to: "be right back", at: 1_700_000_200, origin: .customRule),
            observation(.skipped, source: "hello", to: nil, at: 1_700_000_050),
            observation(.replaced, source: "hidden", to: "x", at: 1_700_000_060, aggregateOnly: true)
        ], to: "auto-fix-decisions.jsonl")
        try write([
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: 1_700_000_400), kind: .autoFixUndone, original: "ghbdtn", converted: "привіт"),
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: 1_700_000_010), kind: .autoFixApplied, original: "a", converted: "b")
        ], to: "replacement-history.jsonl")

        let decisions = TypingDecisionLog.load(directory: directory)

        XCTAssertEqual(decisions.map(\.kind), [.undone, .hint, .replaced, .replaced])
        XCTAssertEqual(decisions.map(\.origin), [nil, .spelling, .rule, .layout])
        XCTAssertEqual(decisions.last?.original, "ghbdtn")
        XCTAssertEqual(decisions.last?.confidence, 0.9)
        let counts = TypingDecisionCounts(decisions)
        XCTAssertEqual([counts.signals, counts.replaced, counts.hints, counts.undone], [4, 2, 1, 1])
    }

    func test_loadOfAnEmptyDirectoryIsEmptyAndClearRemovesTheFiles() throws {
        XCTAssertTrue(TypingDecisionLog.load(directory: directory).isEmpty)
        try write([observation(.replaced, source: "ghbdtn", to: "привіт", at: 1_700_000_100)], to: "auto-fix-decisions.jsonl")
        XCTAssertEqual(TypingDecisionLog.load(directory: directory).count, 1)
        TypingDecisionLog.clear(directory: directory)
        XCTAssertTrue(TypingDecisionLog.load(directory: directory).isEmpty)
    }
}
