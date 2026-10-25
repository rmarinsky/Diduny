@testable import Diduny
import XCTest

/// Tests for the pure decision types behind "Stop after silence":
/// `SpeechProbabilityGate` (hysteresis over VAD probabilities) and
/// `SilenceAutoStopTimer` (countdown and stop after N seconds of silence).
final class SilenceAutoStopTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: - SpeechProbabilityGate

    func testGateOpensAboveOnThresholdAndClosesOnlyBelowOffThreshold() {
        var gate = SpeechProbabilityGate(onThreshold: 0.5, offThreshold: 0.35)

        XCTAssertFalse(gate.update(probability: 0.4))
        XCTAssertTrue(gate.update(probability: 0.6))
        XCTAssertTrue(gate.update(probability: 0.4)) // between thresholds: stays speech
        XCTAssertFalse(gate.update(probability: 0.3))
        XCTAssertFalse(gate.update(probability: 0.45)) // between thresholds: stays silence
    }

    // MARK: - SilenceAutoStopTimer

    func testStopsAfterTimeoutWithCountdownInLastThreeSeconds() {
        var timer = SilenceAutoStopTimer(timeout: 5)

        XCTAssertEqual(timer.update(isSpeech: true, at: at(0)), .keepRecording)
        XCTAssertEqual(timer.update(isSpeech: false, at: at(1.9)), .keepRecording)
        XCTAssertEqual(timer.update(isSpeech: false, at: at(2)), .countdown(secondsLeft: 3))
        XCTAssertEqual(timer.update(isSpeech: false, at: at(3.5)), .countdown(secondsLeft: 2))
        XCTAssertEqual(timer.update(isSpeech: false, at: at(4.2)), .countdown(secondsLeft: 1))
        XCTAssertEqual(timer.update(isSpeech: false, at: at(5)), .stop)
    }

    func testStopIsReportedOnlyOnce() {
        var timer = SilenceAutoStopTimer(timeout: 2)

        _ = timer.update(isSpeech: true, at: at(0))
        XCTAssertEqual(timer.update(isSpeech: false, at: at(2)), .stop)
        XCTAssertEqual(timer.update(isSpeech: false, at: at(3)), .keepRecording)
        XCTAssertEqual(timer.update(isSpeech: true, at: at(4)), .keepRecording)
    }

    func testNeverStopsBeforeFirstSpeech() {
        var timer = SilenceAutoStopTimer(timeout: 1)

        XCTAssertEqual(timer.update(isSpeech: false, at: at(0)), .keepRecording)
        XCTAssertEqual(timer.update(isSpeech: false, at: at(60)), .keepRecording)
    }

    func testSpeechDuringCountdownCancelsIt() {
        var timer = SilenceAutoStopTimer(timeout: 5)

        _ = timer.update(isSpeech: true, at: at(0))
        XCTAssertEqual(timer.update(isSpeech: false, at: at(3)), .countdown(secondsLeft: 2))
        XCTAssertEqual(timer.update(isSpeech: true, at: at(3.5)), .keepRecording)
        XCTAssertEqual(timer.update(isSpeech: false, at: at(5)), .keepRecording)
        XCTAssertEqual(timer.update(isSpeech: false, at: at(8.5)), .stop)
    }

    func testPausesShorterThanTimeoutNeverStop() {
        var timer = SilenceAutoStopTimer(timeout: 5)

        for second in stride(from: 0.0, through: 60, by: 4.5) {
            XCTAssertEqual(timer.update(isSpeech: true, at: at(second)), .keepRecording)
            XCTAssertNotEqual(timer.update(isSpeech: false, at: at(second + 4.4)), .stop)
        }
    }

    // MARK: - SilenceAutoStopMonitor (bundled Silero model)

    /// Fixtures/speech-tts.m4a: 2 s of macOS TTS speech.
    @MainActor
    func testMonitorStopsAfterSpeechThenSilence() async throws {
        let speech = try AudioConverter.convertToWhisperFormat(audioData: Data(contentsOf: fixtureURL("speech-tts.m4a")))
        var decisions: [SilenceAutoStopTimer.Decision] = []
        let stopped = expectation(description: "stop after silence")
        let monitor = try XCTUnwrap(SilenceAutoStopMonitor(timeout: 1) { decision in
            decisions.append(decision)
            if decision == .stop { stopped.fulfill() }
        })

        monitor.append(samples: speech)
        let silence = Task {
            for _ in 0 ..< 30 {
                monitor.append(samples: [Float](repeating: 0, count: 1600)) // 100 ms
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await fulfillment(of: [stopped], timeout: 5)
        silence.cancel()

        XCTAssertEqual(decisions.first, .countdown(secondsLeft: 1))
        XCTAssertEqual(decisions.last, .stop)
    }

    @MainActor
    func testMonitorNeverStopsOnSilenceAlone() async throws {
        var decisions: [SilenceAutoStopTimer.Decision] = []
        let monitor = try XCTUnwrap(SilenceAutoStopMonitor(timeout: 1) { decisions.append($0) })

        for _ in 0 ..< 15 {
            monitor.append(samples: [Float](repeating: 0, count: 1600))
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(decisions, [])
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    func testShortTimeoutCountsDownWholeWindow() {
        var timer = SilenceAutoStopTimer(timeout: 2)

        _ = timer.update(isSpeech: true, at: at(0))
        XCTAssertEqual(timer.update(isSpeech: false, at: at(0.1)), .countdown(secondsLeft: 2))
        XCTAssertEqual(timer.update(isSpeech: false, at: at(1.5)), .countdown(secondsLeft: 1))
    }
}
