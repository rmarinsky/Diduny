@testable import Diduny
import XCTest

final class WordDiffTests: XCTestCase {
    func testIdenticalTextHasNoDifference() {
        let result = WordDiff.compare("Нагадай мені завтра", reference: "Нагадай мені завтра")
        XCTAssertEqual(result.rate, 0)
        XCTAssertEqual(result.ops, [.equal("Нагадай"), .equal("мені"), .equal("завтра")])
    }

    func testNothingIsNormalised() {
        // Case, punctuation and apostrophe variants all count as differences.
        let result = WordDiff.compare("п’ятниці, Fly", reference: "п'ятниці fly.")
        XCTAssertEqual(result.ops, [
            .substituted(word: "п’ятниці,", reference: "п'ятниці"),
            .substituted(word: "Fly", reference: "fly."),
        ])
        XCTAssertEqual(result.rate, 1)
    }

    func testMissingAndInsertedWords() {
        let result = WordDiff.compare("логи на сервері", reference: "перевірити логи на")
        XCTAssertEqual(result.ops, [.missing("перевірити"), .equal("логи"), .equal("на"), .inserted("сервері")])
        XCTAssertEqual(result.rate, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testEmptyReference() {
        XCTAssertEqual(WordDiff.compare("", reference: "").rate, 0)
        XCTAssertEqual(WordDiff.compare("щось", reference: "").rate, 1)
    }

    func testRunSummaryUsesReferenceAndVotes() {
        let clip = UUID()
        var run = BenchmarkRun(
            language: "uk",
            clips: [.init(id: clip, title: "c", durationSeconds: 10, createdAt: Date())],
            engines: [.init(id: "diduny", name: "Diduny", kind: .cloud), .init(id: "parakeet-v3", name: "Parakeet V3", kind: .local)],
            referenceEngineID: "diduny"
        )
        run.cells[BenchmarkRun.key(clip, "diduny")] = .init(text: "a b c d", seconds: 1)
        run.cells[BenchmarkRun.key(clip, "parakeet-v3")] = .init(text: "a b x d", seconds: 0.2, loadSeconds: 0.5)
        run.votes[clip] = "parakeet-v3"

        XCTAssertNil(run.summary(for: "diduny").rate)
        let parakeet = run.summary(for: "parakeet-v3")
        XCTAssertEqual(parakeet.rate ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(parakeet.loadSeconds, 0.5)
        XCTAssertEqual(parakeet.votes, 1)

        run.referenceEngineID = "parakeet-v3"
        XCTAssertEqual(run.summary(for: "diduny").rate ?? -1, 0.25, accuracy: 0.0001)
    }

    func testRelaxedModeIgnoresCaseAndPunctuationButKeepsOriginalWords() {
        let result = WordDiff.compare("Ну, Блять — офігеть.", reference: "Ну блять офігеть", strict: false)
        XCTAssertEqual(result.ops, [.equal("Ну,"), .equal("Блять"), .equal("офігеть.")])
        XCTAssertEqual(result.rate, 0)
        XCTAssertEqual(result.referenceWords, 3)
    }

    func testRelaxedModeStillCountsRealWordChanges() {
        let result = WordDiff.compare("всі пл-реквести", reference: "Всі пул-реквести,", strict: false)
        XCTAssertEqual(result.ops, [.equal("всі"), .substituted(word: "пл-реквести", reference: "пул-реквести,")])
        XCTAssertEqual(result.errors, 1)
    }
}
