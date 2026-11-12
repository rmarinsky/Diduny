import Foundation
import Testing
@testable import Diduny

/// `AsyncTranscriptionJobService.waitLoop`: when waiting for a cloud job ends.
struct AsyncJobWaitTests {
    private struct StreamDropped: Error {}

    private func status(_ value: String, text: String? = nil) throws -> JobStatusResponse {
        let result = text.map { #","result":{"text":"\#($0)"}"# } ?? ""
        let json = #"{"jobId":"j","status":"\#(value)","createdAt":"","updatedAt":""\#(result)}"#
        return try JSONDecoder().decode(JobStatusResponse.self, from: Data(json.utf8))
    }

    private func transcript(_ result: JobTranscriptionResult) -> GeneratedTranscript {
        GeneratedTranscript(text: result.text)
    }

    @Test func goneJobIsFinalOnFirstPoll() async {
        var polls = 0
        await #expect(throws: JobGoneError.self) {
            _ = try await AsyncTranscriptionJobService.waitLoop(
                deadline: .distantFuture,
                stream: { throw StreamDropped() },
                status: { _ in polls += 1; throw JobGoneError(statusCode: 404) },
                transcript: transcript, sleep: { _ in }, onProgressUpdate: { _ in }
            )
        }
        #expect(polls == 1)
    }

    @Test func stopsAfterTenRoundsWithoutAnAnswer() async {
        var rounds = 0
        await #expect(throws: JobWaitInterruptedError.unreachable) {
            _ = try await AsyncTranscriptionJobService.waitLoop(
                deadline: .distantFuture,
                stream: { throw StreamDropped() },
                status: { _ in rounds += 1; return nil },
                transcript: transcript, sleep: { _ in }, onProgressUpdate: { _ in }
            )
        }
        #expect(rounds == AsyncTranscriptionJobService.maxConsecutiveUnreachableRounds)
    }

    @Test func answerResetsTheUnreachableCount() async throws {
        var round = 0
        let result = try await AsyncTranscriptionJobService.waitLoop(
            deadline: .distantFuture,
            stream: { throw StreamDropped() },
            status: { _ in
                round += 1
                if round == 9 { return try status("processing") }
                if round == 18 { return try status("completed", text: "done") }
                return nil
            },
            transcript: transcript, sleep: { _ in }, onProgressUpdate: { _ in }
        )
        #expect(result.text == "done")
    }

    /// The Mac slept past the deadline: the job finished meanwhile and is still picked up.
    @Test func pollsOnceMoreAfterTheDeadline() async throws {
        let result = try await AsyncTranscriptionJobService.waitLoop(
            deadline: Date().addingTimeInterval(-1),
            stream: { Issue.record("no stream after the deadline"); throw StreamDropped() },
            status: { _ in try status("completed", text: "late") },
            transcript: transcript, sleep: { _ in }, onProgressUpdate: { _ in }
        )
        #expect(result.text == "late")
    }

    @Test func timesOutWhenTheJobIsStillRunningAfterTheDeadline() async {
        await #expect(throws: JobWaitInterruptedError.timedOut) {
            _ = try await AsyncTranscriptionJobService.waitLoop(
                deadline: Date().addingTimeInterval(-1),
                stream: { throw StreamDropped() },
                status: { _ in try status("processing") },
                transcript: transcript, sleep: { _ in }, onProgressUpdate: { _ in }
            )
        }
    }

    @Test func onlyNetworkAndInterruptedWaitsKeepTheJob() {
        #expect(JobWaitInterruptedError.jobMayStillFinish(after: URLError(.timedOut)))
        #expect(JobWaitInterruptedError.jobMayStillFinish(after: JobWaitInterruptedError.unreachable))
        #expect(!JobWaitInterruptedError.jobMayStillFinish(after: JobGoneError(statusCode: 410)))
        #expect(!JobWaitInterruptedError.jobMayStillFinish(after: TranscriptionError.apiError("failed")))
    }
}
