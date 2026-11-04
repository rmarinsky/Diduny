@testable import Diduny
import XCTest

final class MeetingBackgroundFinalizationTests: XCTestCase {
    private let eighteenMinutes: TimeInterval = 18 * 60

    private func progress(
        _ stage: QueueProgress.Stage,
        provider: TranscriptionProvider = .cloud,
        total: TimeInterval? = nil,
        fraction: Double? = nil,
        processed: TimeInterval? = nil,
        secondsLeft: TimeInterval? = nil
    ) -> QueueProgress {
        QueueProgress(
            stage: stage,
            provider: provider,
            totalSeconds: total ?? eighteenMinutes,
            fraction: fraction,
            processedSeconds: processed,
            secondsLeft: secondsLeft
        )
    }

    // MARK: - Formatting (row and detail lines)

    func test_cloudTranscribing_showsEstimatedMinutesAndPercent() {
        let value = progress(.transcribing, fraction: 0.62, processed: 11.5 * 60)
        XCTAssertEqual(QueueProgressFormatter.rowLine(value), "Transcribing · ≈ 11 of 18 min · 62%")
        XCTAssertEqual(QueueProgressFormatter.detailLine(value), "Transcribing · ≈ 11 of 18 min")
    }

    func test_localTranscribing_showsExactMinutes() {
        let value = progress(.transcribing, provider: .local, fraction: 0.62, processed: 11.5 * 60)
        XCTAssertEqual(QueueProgressFormatter.rowLine(value), "Transcribing · 11 of 18 min · 62%")
        XCTAssertEqual(QueueProgressFormatter.detailLine(value), "Transcribing · 11 of 18 min")
    }

    func test_shortRecording_usesSeconds() {
        let value = progress(.transcribing, total: 40, fraction: 0.62, processed: 25)
        XCTAssertEqual(QueueProgressFormatter.rowLine(value), "Transcribing · ≈ 25 of 40 s · 62%")
    }

    func test_uploading_showsPercentInRowOnly() {
        let value = progress(.uploading, fraction: 0.46)
        XCTAssertEqual(QueueProgressFormatter.rowLine(value), "Uploading · 46%")
        XCTAssertEqual(QueueProgressFormatter.detailLine(value), "Uploading")
        XCTAssertNil(QueueProgressFormatter.timeLeft(value))
    }

    func test_stagesWithoutFraction_showStageNameOnly() {
        XCTAssertEqual(QueueProgressFormatter.rowLine(progress(.queued)), "Queued")
        XCTAssertEqual(QueueProgressFormatter.rowLine(progress(.preparing)), "Preparing audio")
        XCTAssertEqual(QueueProgressFormatter.rowLine(progress(.finishing)), "Finishing")
        XCTAssertNil(QueueProgressFormatter.barFraction(progress(.finishing)))
    }

    func test_timeLeft_roundsUpToMinutesOrFiveSeconds() {
        XCTAssertEqual(QueueProgressFormatter.timeLeft(progress(.transcribing, secondsLeft: 90)), "~2 min left")
        XCTAssertEqual(QueueProgressFormatter.timeLeft(progress(.transcribing, secondsLeft: 12)), "~15 s left")
        XCTAssertEqual(QueueProgressFormatter.timeLeft(progress(.transcribing, secondsLeft: 3)), "~5 s left")
        XCTAssertNil(QueueProgressFormatter.timeLeft(progress(.transcribing, secondsLeft: nil)))
    }

    func test_cloudEstimate_neverShowsMoreThan95Percent() {
        let value = progress(.transcribing, fraction: 0.99, processed: 17.8 * 60)
        XCTAssertEqual(QueueProgressFormatter.percent(value), 95)
        XCTAssertEqual(QueueProgressFormatter.barFraction(value), 0.95)
        let local = progress(.transcribing, provider: .local, fraction: 0.99, processed: 17.8 * 60)
        XCTAssertEqual(QueueProgressFormatter.percent(local), 99)
    }

    // MARK: - Cloud estimate

    func test_cloudEstimate_risesWithTimeAndStopsAt95Percent() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let estimate = CloudTranscriptionEstimate(audioSeconds: 600, startedAt: start)
        let expected = estimate.expectedSeconds

        var previous = -1.0
        for second in stride(from: 0.0, through: expected * 3, by: expected / 20) {
            let fraction = estimate.fraction(at: start.addingTimeInterval(second))
            XCTAssertGreaterThanOrEqual(fraction, previous)
            XCTAssertLessThanOrEqual(fraction, CloudTranscriptionEstimate.maxFraction)
            previous = fraction
        }
        XCTAssertEqual(estimate.fraction(at: start.addingTimeInterval(expected / 2)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(estimate.fraction(at: start.addingTimeInterval(expected * 3)), 0.95)
    }

    func test_cloudEstimate_timeLeftEndsWhenJobRunsLong() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let estimate = CloudTranscriptionEstimate(audioSeconds: 600, startedAt: start)
        let expected = estimate.expectedSeconds

        XCTAssertEqual(estimate.secondsLeft(at: start.addingTimeInterval(expected / 2)) ?? -1, expected / 2, accuracy: 0.0001)
        XCTAssertNil(estimate.secondsLeft(at: start.addingTimeInterval(expected + 1)))
    }

    // MARK: - Stop routing

    func test_stopRoute_cloudWithAcceptedLiveTranscript_usesIt() {
        XCTAssertEqual(
            AppDelegate.meetingStopRoute(provider: .cloud, acceptsRealtimeTranscript: true, hasLocalModel: true),
            .realtimeTranscript
        )
    }

    func test_stopRoute_cloudWithoutLiveTranscript_goesToQueue() {
        XCTAssertEqual(
            AppDelegate.meetingStopRoute(provider: .cloud, acceptsRealtimeTranscript: false, hasLocalModel: true),
            .queueCloud(localFallback: true)
        )
        XCTAssertEqual(
            AppDelegate.meetingStopRoute(provider: .cloud, acceptsRealtimeTranscript: false, hasLocalModel: false),
            .queueCloud(localFallback: false)
        )
    }

    func test_stopRoute_local_queuesOrSavesOnly() {
        XCTAssertEqual(
            AppDelegate.meetingStopRoute(provider: .local, acceptsRealtimeTranscript: false, hasLocalModel: true),
            .queueLocal
        )
        XCTAssertEqual(
            AppDelegate.meetingStopRoute(provider: .local, acceptsRealtimeTranscript: false, hasLocalModel: false),
            .saveOnly
        )
    }

    func test_usageLimit_fallsBackToLocalOnlyWhenAllowedAndModelReady() {
        let limit = TranscriptionError.usageLimitExceeded(usedHours: 10, limitHours: 10)
        XCTAssertEqual(
            RecordingQueueService.usageLimitFallbackProvider(
                for: limit, provider: .cloud, allowsLocalFallback: true, hasLocalModel: true
            ),
            .local
        )
        XCTAssertNil(RecordingQueueService.usageLimitFallbackProvider(
            for: limit, provider: .cloud, allowsLocalFallback: true, hasLocalModel: false
        ))
        XCTAssertNil(RecordingQueueService.usageLimitFallbackProvider(
            for: limit, provider: .cloud, allowsLocalFallback: false, hasLocalModel: true
        ))
        XCTAssertNil(RecordingQueueService.usageLimitFallbackProvider(
            for: .invalidResponse, provider: .cloud, allowsLocalFallback: true, hasLocalModel: true
        ))
    }
}
