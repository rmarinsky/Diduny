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

    @Test("Translation semicolons become commas")
    func translationSemicolons() {
        #expect(
            TranscriptCleanupService.replaceSemicolonsWithCommas("I looked at it; it doesn't work ; really.")
                == "I looked at it, it doesn't work, really."
        )
    }

    @Test("Chat messages lowercase the first word across languages and preserve inner punctuation")
    func chatMessageFormatting() {
        #expect(ClipboardService.preparedMessageText(" Так, добре. Зараз перевірю. ", mode: .chat) == "так, добре. Зараз перевірю")
        #expect(ClipboardService.preparedMessageText("Роман перевірить.", mode: .chat) == "роман перевірить")
        #expect(ClipboardService.preparedMessageText("API готовий.", mode: .chat) == "api готовий")
        #expect(ClipboardService.preparedMessageText("ТАК.", mode: .chat) == "так")
        #expect(ClipboardService.preparedMessageText("Так?", mode: .chat) == "так?")
        #expect(ClipboardService.preparedMessageText("Так!", mode: .chat) == "так!")
        #expect(ClipboardService.preparedMessageText("Це я.", mode: .chat) == "це я")
        #expect(ClipboardService.preparedMessageText("Буду о 5.", mode: .chat) == "буду о 5")
        #expect(ClipboardService.preparedMessageText("Підпис Р.", mode: .chat) == "підпис Р")
        #expect(ClipboardService.preparedMessageText("https://example.com", mode: .chat) == "https://example.com")
        #expect(ClipboardService.preparedMessageText("`Hello.world.`", mode: .chat) == "`hello.world.`")
        #expect(ClipboardService.preparedMessageText("Так...", mode: .chat) == "так...")
        #expect(ClipboardService.preparedMessageText("Так.", mode: .normal) == "Так.")
        #expect(ClipboardService.preparedMessageText("Так.\n\nДобре.", mode: .chat) == "Так.\n\nДобре.")
        for type in [Recording.RecordingType.voice, .translation] {
            #expect(ClipboardService.preparedMessageText("Так.", recordingType: type, mode: .chat) == "так")
        }
        for type in [Recording.RecordingType.meeting, .meetingTranslation, .fileTranscription] {
            #expect(ClipboardService.preparedMessageText("Так.", recordingType: type, mode: .chat) == "Так.")
        }
        #expect(ClipboardService.preparedMessageText("Dr.", mode: .chat) == "dr")
        #expect(ClipboardService.preparedMessageText("Bonjour Marie.", mode: .chat) == "bonjour Marie")
        #expect(ClipboardService.preparedMessageText("Übermorgen geht es los.", mode: .chat) == "übermorgen geht es los")
        #expect(ClipboardService.preparedMessageText("«Роман перевірить?»", mode: .chat) == "«роман перевірить?»")
        #expect(ClipboardService.preparedMessageText("你好。", mode: .chat) == "你好")
        #expect(ClipboardService.preparedMessageText("こんにちは．", mode: .chat) == "こんにちは")
        #expect(ClipboardService.preparedMessageText("شکریہ۔", mode: .chat) == "شکریہ")
        #expect(ClipboardService.preparedMessageText("你好？！", mode: .chat) == "你好？！")
        #expect(ClipboardService.preparedMessageText("Так…", mode: .chat) == "так…")
        #expect(ClipboardService.preparedMessageText("", mode: .chat) == "")
        let long = "Так, " + String(repeating: "довге повідомлення ", count: 20) + "готове."
        #expect(ClipboardService.preparedMessageText(long, mode: .chat) == long)
    }

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

    @Test("Provider segments supply speaker labels when tokens do not")
    func providerSegmentsSupplySpeakerLabels() throws {
        let json = """
        {
          "text": "Hello Roman.",
          "tokens": [
            { "text": "Hello Roman.", "start_ms": 0, "end_ms": 800 }
          ],
          "segments": [
            { "text": "Hello Roman.", "start_ms": 0, "end_ms": 800, "speaker": "1" }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(
            result.generatedTranscript(preferSpeakerDiarization: true).text ==
                "[00:00] Speaker 1: Hello Roman."
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

    @Test("Soniox token fragments preserve provider spacing in timed phrases")
    func sonioxTokenFragmentsPreserveProviderSpacing() throws {
        let json = """
        {
          "text": "Всіх вітаю.",
          "tokens": [
            { "text": "В", "start_ms": 0, "end_ms": 100 },
            { "text": "сі", "start_ms": 100, "end_ms": 200 },
            { "text": "х ", "start_ms": 200, "end_ms": 300 },
            { "text": "ві", "start_ms": 300, "end_ms": 400 },
            { "text": "таю", "start_ms": 400, "end_ms": 500 },
            { "text": ".", "start_ms": 500, "end_ms": 600 }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(result.generatedTranscript(preferSpeakerDiarization: false).segments == [
            TimedTranscriptSegment(startMilliseconds: 0, endMilliseconds: 600, text: "Всіх вітаю.")
        ])
    }

    @Test("Job result preserves phrase timestamps without changing plain text")
    func jobResultPreservesPhraseTimestamps() throws {
        let json = """
        {
          "text": "First thought. Second thought!",
          "words": [
            { "word": "First", "start": 1.2, "end": 1.5 },
            { "word": "thought", "start": 1.5, "end": 1.9 },
            { "word": ".", "start": 1.9, "end": 2.0 },
            { "word": "Second", "start": 3.4, "end": 3.8 },
            { "word": "thought", "start": 3.8, "end": 4.2 },
            { "word": "!", "start": 4.2, "end": 4.3 }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))
        let transcript = result.generatedTranscript(preferSpeakerDiarization: false)

        #expect(transcript.text == "First thought. Second thought!")
        #expect(transcript.segments == [
            TimedTranscriptSegment(startMilliseconds: 1200, endMilliseconds: 2000, text: "First thought."),
            TimedTranscriptSegment(startMilliseconds: 3400, endMilliseconds: 4300, text: "Second thought!")
        ])
    }

    @Test("Provider segments keep their exact boundaries")
    func providerSegmentsKeepExactBoundaries() throws {
        let json = """
        {
          "text": "Two sentences. One provider segment.",
          "segments": [
            {
              "text": "Two sentences. One provider segment.",
              "start_ms": 1200,
              "end_ms": 4300
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(result.generatedTranscript(preferSpeakerDiarization: false).segments == [
            TimedTranscriptSegment(
                startMilliseconds: 1200,
                endMilliseconds: 4300,
                text: "Two sentences. One provider segment."
            )
        ])
    }

    @Test("Provider segments never invent missing timestamps")
    func providerSegmentsNeverInventMissingTimestamps() throws {
        let json = """
        {
          "text": "Known start. Unknown time.",
          "segments": [
            { "text": "Known start.", "start_ms": 1200 },
            { "text": "Unknown time." }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(result.generatedTranscript(preferSpeakerDiarization: false).segments == [
            TimedTranscriptSegment(startMilliseconds: 1200, endMilliseconds: nil, text: "Known start.")
        ])
    }

    @Test("Provider segments take precedence over word tokens for persistence")
    func providerSegmentsTakePrecedenceForPersistence() throws {
        let json = """
        {
          "text": "First thought. Second thought.",
          "tokens": [
            { "text": "First ", "start_ms": 1000, "end_ms": 1500 },
            { "text": "thought.", "start_ms": 1500, "end_ms": 2000 }
          ],
          "segments": [
            {
              "text": "First thought. Second thought.",
              "start_ms": 1000,
              "end_ms": 5000
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(result.generatedTranscript(preferSpeakerDiarization: false).segments == [
            TimedTranscriptSegment(
                startMilliseconds: 1000,
                endMilliseconds: 5000,
                text: "First thought. Second thought."
            )
        ])
    }

    @Test("Untimed provider segments fall back to timed word phrases")
    func untimedProviderSegmentsFallBackToTimedWordPhrases() throws {
        let json = """
        {
          "text": "Timed words.",
          "words": [
            { "word": "Timed", "start": 1.2, "end": 1.6 },
            { "word": "words", "start": 1.6, "end": 2.0 },
            { "word": ".", "start": 2.0, "end": 2.1 }
          ],
          "segments": [
            { "text": "Untimed provider output." }
          ]
        }
        """

        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: Data(json.utf8))

        #expect(result.generatedTranscript(preferSpeakerDiarization: false).segments == [
            TimedTranscriptSegment(startMilliseconds: 1200, endMilliseconds: 2100, text: "Timed words.")
        ])
    }

    @Test("Batch upload diagnostics include source duration and prepared payload")
    func batchUploadDiagnosticsIncludeUploadShape() {
        let diagnostics = BatchUploadDiagnostics(
            source: "MRG podcast - vol.6.mp4",
            sourceDurationSeconds: 9994,
            originalBytes: 155_900_000,
            preparedBytes: 51_200_000,
            filename: "recording.flac",
            contentType: "audio/flac"
        )

        #expect(
            diagnostics.message ==
                "source=MRG podcast - vol.6.mp4 sourceDuration=2:46:34 originalBytes=155900000 preparedBytes=51200000 filename=recording.flac contentType=audio/flac"
        )
    }
}
