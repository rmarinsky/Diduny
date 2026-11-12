import Foundation
import Testing
@testable import Diduny

/// When notes may start, when they are redone, and how failed automatic notes are retried.
@MainActor
struct NotesQueueTests {
    private func recording(text: String? = "We agreed.", processedAt: Date? = Date(timeIntervalSince1970: 1000),
                           status: Recording.ProcessingStatus = .transcribed) -> Recording {
        Recording(id: UUID(), createdAt: Date(), type: .meeting, audioFileName: "a.m4a", durationSeconds: 60,
                  fileSizeBytes: 10, status: status, transcriptionText: text, processedAt: processedAt, sourceDevice: nil)
    }

    // MARK: - Fix 1: a requested note does not wait behind an automatic one

    @Test func requestedJobRunsPastAWaitingAutomaticJob() {
        let automatic = NotesService.blocker(automatic: true, waitsForIdle: true, isCapturing: false,
                                             waitForPower: true, isOnPower: false, idleSeconds: 0)
        let requested = NotesService.blocker(automatic: false, waitsForIdle: false, isCapturing: false,
                                             waitForPower: true, isOnPower: false, idleSeconds: 0)
        #expect(automatic != nil)
        #expect(requested == nil)
        #expect(NotesService.firstRunnable([automatic, requested]) == 1)
        #expect(NotesService.firstRunnable([automatic, automatic]) == nil)
    }

    // MARK: - Fix 9: only a live capture blocks notes

    @Test func liveCaptureBlocksEveryJobAndNothingElseBlocksRequestedOnes() {
        #expect(NotesService.blocker(automatic: false, waitsForIdle: false, isCapturing: true,
                                     waitForPower: false, isOnPower: true, idleSeconds: 999) != nil)
        #expect(NotesService.blocker(automatic: true, waitsForIdle: true, isCapturing: false,
                                     waitForPower: true, isOnPower: true, idleSeconds: 999) == nil)
    }

    // MARK: - Fix 4: notes from a transcript that changed

    @Test func transcriptChangedWhenRedoneEditedOrNoLongerReady() {
        let written = recording()
        var same = written
        same.processedAt = written.processedAt?.addingTimeInterval(0.4)
        #expect(!RecordingNote.transcriptChanged(from: written, to: same))

        var redone = written
        redone.processedAt = written.processedAt?.addingTimeInterval(60)
        #expect(RecordingNote.transcriptChanged(from: written, to: redone))

        var edited = written
        edited.transcriptionText = "We did not agree."
        #expect(RecordingNote.transcriptChanged(from: written, to: edited))

        var processing = written
        processing.status = .processing
        #expect(RecordingNote.transcriptChanged(from: written, to: processing))
        #expect(RecordingNote.transcriptChanged(from: written, to: nil))
    }

    @Test func noteRemembersItsTranscriptAndKnowsWhenItIsStale() {
        let source = recording()
        let note = NotesService.note(from: NotesDraft(summary: "S"), recording: source, template: .meeting,
                                     writer: "test", withTimes: false)
        #expect(note.transcriptProcessedAt == source.processedAt)
        #expect(!note.isStale(for: source))
        var redone = source
        redone.processedAt = source.processedAt?.addingTimeInterval(120)
        #expect(note.isStale(for: redone))
    }

    @Test func noteWithoutTranscriptDateDecodesAndIsNeverStale() throws {
        let json = #"{"id":"\#(UUID())","recordingID":"\#(UUID())","createdAt":"2026-01-01T00:00:00Z","writer":"w","template":"meeting","summary":"","decisions":[],"actionItems":[],"openQuestions":[],"points":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(RecordingNote.self, from: Data(json.utf8))
        #expect(note.transcriptProcessedAt == nil)
        #expect(!note.isStale(for: recording()))
    }

    // MARK: - Fix 8: failed automatic notes retry with growing pauses, then stop

    @Test func failedAutomaticNotesBackOffAndStop() throws {
        let suite = "NotesQueueTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 10000)
        let failures = AutomaticNotesFailures(defaults: defaults, now: { now })
        let id = UUID()

        #expect(failures.isRetryDue(id))
        failures.record(id)
        #expect(!failures.isRetryDue(id))
        now += 299
        #expect(!failures.isRetryDue(id))
        now += 1
        #expect(failures.isRetryDue(id))

        failures.record(id)
        now += 300
        #expect(!failures.isRetryDue(id), "second pause is 10 minutes")
        now += 300
        #expect(failures.isRetryDue(id))

        failures.record(id)
        failures.record(id)
        now += 100_000
        #expect(!failures.isRetryDue(id), "stops after \(AutomaticNotesFailures.maxAttempts) attempts")

        // Kept across launches.
        #expect(!AutomaticNotesFailures(defaults: defaults, now: { now }).isRetryDue(id))
        failures.clear(id)
        #expect(failures.isRetryDue(id))
    }
}
