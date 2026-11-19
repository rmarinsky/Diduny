import XCTest
@testable import PapugaKit

/// A contradiction is the correct word that *ended* a run — the only position
/// the controller lets one occupy. It is trimmed before judgment, so the rest
/// of the run keeps its fix instead of being annihilated by one real word; and
/// a contradiction that somehow survives trimming can only ever produce a
/// proposal, never a silent replacement.
final class LayoutIncidentContradictionTests: XCTestCase {

    private func incident(strong: Int, contradictions: Int) -> LayoutIncidentTracker {
        var incident = LayoutIncidentTracker()
        for index in 0..<strong {
            incident.append(LayoutIncidentToken(
                original: "ghbdsn\(index)",
                candidate: "привіт\(index)",
                boundary: " ",
                targetLayoutID: "uk",
                evidence: .strong,
                boundaryCaret: 10 * (index + 1)
            ))
        }
        for index in 0..<contradictions {
            incident.append(LayoutIncidentToken(
                original: "hello\(index)",
                candidate: "руддщ\(index)",
                boundary: " ",
                targetLayoutID: "uk",
                evidence: .contradiction
            ))
        }
        return incident
    }

    func test_trailingContradictionNoLongerAnnihilatesTheRun() {
        let mostlyGood = incident(strong: 9, contradictions: 1)
        let judged = mostlyGood.judgedTokens

        XCTAssertEqual(judged.count, 9, "the correct word is trimmed, the mistake run survives")
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.1,
                scoreCandidate: 0.95,
                threshold: 0.35,
                proposalWindow: 0.22,
                hasContradiction: judged.contains { $0.evidence == .contradiction }
            ),
            .replace
        )
    }

    func test_trimmedRunAnchorsAtTheLastJudgedToken() {
        let mostlyGood = incident(strong: 3, contradictions: 1)
        XCTAssertEqual(mostlyGood.judgedTokens.last?.boundaryCaret, 30)
    }

    func test_multipleTrailingContradictionsAllTrim() {
        let run = incident(strong: 2, contradictions: 2)
        XCTAssertEqual(run.judgedTokens.count, 2)
    }

    /// Auto-replacement must never be reachable while a contradiction remains
    /// inside the judged run, whatever the scores: silently rewriting a
    /// sentence containing a word the user meant is the worst failure mode
    /// this app has.
    func test_survivingContradictionCanNeverProduceAReplacement() {
        for original in stride(from: 0.0, through: 0.5, by: 0.1) {
            XCTAssertNotEqual(
                LayoutIncidentTracker.runVerdict(
                    scoreOriginal: original,
                    scoreCandidate: 1.0,
                    threshold: 0.35,
                    proposalWindow: 0.22,
                    hasContradiction: true
                ),
                .replace,
                "scoreOriginal=\(original) reached .replace with a contradiction present"
            )
        }
    }

    func test_weakMarginStillDiscardsRegardlessOfContradictions() {
        XCTAssertEqual(
            LayoutIncidentTracker.runVerdict(
                scoreOriginal: 0.5,
                scoreCandidate: 0.55,
                threshold: 0.35,
                proposalWindow: 0.1,
                hasContradiction: true
            ),
            .discard
        )
    }
}
