import XCTest
@testable import PapugaKit

final class TypingSpeedTestEngineTests: XCTestCase {
    func test_emptyInputHasFullAccuracyAndZeroSpeed() {
        let metrics = TypingSpeedTestEngine.metrics(
            prompt: "привіт",
            typedText: "",
            elapsedSeconds: 0
        )

        XCTAssertEqual(metrics.typedCharacters, 0)
        XCTAssertEqual(metrics.correctCharacters, 0)
        XCTAssertEqual(metrics.errorCharacters, 0)
        XCTAssertEqual(metrics.accuracy, 1)
        XCTAssertEqual(metrics.wordsPerMinute, 0)
        XCTAssertFalse(metrics.isComplete)
    }

    func test_perfectInputCalculatesWPMAndCPMFromCorrectCharacters() {
        let metrics = TypingSpeedTestEngine.metrics(
            prompt: "hello world",
            typedText: "hello world",
            elapsedSeconds: 30
        )

        XCTAssertEqual(metrics.typedCharacters, 11)
        XCTAssertEqual(metrics.correctCharacters, 11)
        XCTAssertEqual(metrics.errorCharacters, 0)
        XCTAssertEqual(metrics.accuracy, 1)
        XCTAssertEqual(metrics.charactersPerMinute, 22)
        XCTAssertEqual(metrics.wordsPerMinute, 4.4)
        XCTAssertTrue(metrics.isComplete)
    }

    func test_wrongAndExtraCharactersCountAsErrors() {
        let metrics = TypingSpeedTestEngine.metrics(
            prompt: "test",
            typedText: "tent!",
            elapsedSeconds: 60
        )

        XCTAssertEqual(metrics.typedCharacters, 5)
        XCTAssertEqual(metrics.correctCharacters, 3)
        XCTAssertEqual(metrics.errorCharacters, 2)
        XCTAssertEqual(metrics.accuracy, 0.6)
        XCTAssertEqual(metrics.progress, 1)
        XCTAssertFalse(metrics.isComplete)
    }

    func test_partialInputTracksProgressButIsNotComplete() {
        let metrics = TypingSpeedTestEngine.metrics(
            prompt: "abcdef",
            typedText: "abc",
            elapsedSeconds: 12
        )

        XCTAssertEqual(metrics.correctCharacters, 3)
        XCTAssertEqual(metrics.progress, 0.5)
        XCTAssertFalse(metrics.isComplete)
    }
}
