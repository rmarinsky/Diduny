import Foundation
import Testing

@testable import Diduny

// MARK: - TranscriptCleanupService Unit Tests
//
// These tests cover the guard-clause logic of TranscriptCleanupService
// without making real network calls.  The happy-path (backend round-trip)
// is covered by integration / contract tests on the backend side.

@Suite("TranscriptCleanupService guard clauses")
struct TranscriptCleanupServiceTests {

    // MARK: - Empty input

    @Test("Empty string is returned unchanged without hitting the network")
    func emptyInputReturnedAsIs() async {
        // TranscriptCleanupService.shared skips the request for empty input.
        // Even if auth/network is present the result must be the unchanged string.
        let result = await TranscriptCleanupService.shared.clean("", fillerWords: [])
        #expect(result == "")
    }

    @Test("Whitespace-only input is returned unchanged")
    func whitespaceOnlyInputReturnedAsIs() async {
        let result = await TranscriptCleanupService.shared.clean("   \n\t  ", fillerWords: [])
        #expect(result == "   \n\t  ")
    }

    // MARK: - No auth session
    //
    // When AuthService.hasStoredSession == false the service must return rawText immediately.
    // We validate the observable effect (return value equals input) because we cannot easily
    // inject a mock auth service without refactoring the singleton.  The guard in
    // TranscriptCleanupService is `guard AuthService.hasStoredSession else { return rawText }`,
    // so on a test runner without Keychain credentials this path is always exercised.

    @Test("Without a stored session the service returns the raw text unchanged")
    func noSessionReturnsRawText() async {
        // In the test sandbox there is no stored Keychain token, so hasStoredSession == false.
        guard !AuthService.hasStoredSession else {
            // If CI somehow has a session, skip rather than fail.
            return
        }
        let input = "Hello world this is a test."
        let result = await TranscriptCleanupService.shared.clean(input, fillerWords: ["um", "uh"])
        #expect(result == input)
    }

    // MARK: - ClipboardService.preparedText interaction

    @Test(".cleaned behavior trims surrounding whitespace from the already-cleaned text")
    func preparedTextTrimsWhitespace() {
        let padded = "  Hello world  \n"
        let result = ClipboardService.preparedText(padded, behavior: .cleaned)
        #expect(result == "Hello world")
    }

    @Test(".cleaned behavior on already-trimmed text returns it unchanged")
    func preparedTextNoopOnTrimmedInput() {
        let input = "Hello world"
        let result = ClipboardService.preparedText(input, behavior: .cleaned)
        #expect(result == input)
    }

    @Test(".raw behavior returns text completely unchanged including surrounding whitespace")
    func preparedTextRawPreservesEverything() {
        let input = "  \nHello world\n  "
        let result = ClipboardService.preparedText(input, behavior: .raw)
        #expect(result == input)
    }

    @Test(".raw on empty string returns empty string")
    func preparedTextRawEmptyString() {
        #expect(ClipboardService.preparedText("", behavior: .raw) == "")
    }

    @Test(".cleaned on empty string returns empty string")
    func preparedTextCleanedEmptyString() {
        #expect(ClipboardService.preparedText("", behavior: .cleaned) == "")
    }

    @Test("Auto-paste artificial delay stays under 75 ms")
    func autoPasteDelayBudget() {
        let totalArtificialDelayMs =
            (ClipboardService.pasteReadinessDelayNanoseconds / 1_000_000) +
            UInt64(ClipboardService.shortcutKeyHoldMicroseconds / 1_000)

        #expect(totalArtificialDelayMs <= 75)
    }

    // MARK: - Reachability default

    @Test("isReachable is true immediately after service init (optimistic default)")
    func isReachableDefaultsToTrue() {
        // The monitor starts as true so the first dictation after cold launch
        // is not blocked before NWPathMonitor fires its first update.
        #expect(TranscriptCleanupService.shared.isReachable == true)
    }

    // MARK: - Jobs diarization formatting

    @Test("Job result keeps plain text for normal transcription")
    func jobResultKeepsPlainTextWhenDiarizationIsNotPreferred() throws {
        let json = """
        {
          "text": "Plain transcript returned by the backend.",
          "tokens": [
            { "text": "Hello ", "start_ms": 0, "end_ms": 400, "speaker": "1" },
            { "text": "Roman", "start_ms": 400, "end_ms": 800, "speaker": "1" }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(result.outputText(preferSpeakerDiarization: false) == "Plain transcript returned by the backend.")
    }

    @Test("Job result formats speaker diarization with timestamps")
    func jobResultFormatsSpeakerDiarization() throws {
        let json = """
        {
          "text": "Plain transcript returned by the backend.",
          "tokens": [
            { "text": "Hello ", "start_ms": 0, "end_ms": 400, "speaker": "1" },
            { "text": "Roman", "start_ms": 400, "end_ms": 800, "speaker": "1" },
            { "text": "Hi", "start_ms": 1500, "end_ms": 1900, "speaker": "2" }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(
            result.outputText(preferSpeakerDiarization: true) ==
                "[00:00] Speaker 1: Hello Roman\n\n[00:01] Speaker 2: Hi"
        )
    }

    @Test("Job result supports words payload and same-speaker timing gaps")
    func jobResultSupportsWordsPayloadAndTimingGaps() throws {
        let json = """
        {
          "words": [
            { "word": "First sentence.", "start": 0.0, "end": 0.9, "speaker_id": 1 },
            { "word": "Later sentence.", "start": 5.0, "end": 5.7, "speaker_id": 1 }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(
            result.outputText(preferSpeakerDiarization: true) ==
                "[00:00] Speaker 1: First sentence.\n\n[00:05] Speaker 1: Later sentence."
        )
    }

    @Test("Job result inserts spaces between word payload tokens")
    func jobResultInsertsSpacesBetweenWordTokens() throws {
        let json = """
        {
          "words": [
            { "word": "Hello", "start": 0.0, "end": 0.2, "speaker_id": 1 },
            { "word": "Roman", "start": 0.2, "end": 0.5, "speaker_id": 1 },
            { "word": ".", "start": 0.5, "end": 0.6, "speaker_id": 1 }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(result.outputText(preferSpeakerDiarization: true) == "[00:00] Speaker 1: Hello Roman.")
    }
}
