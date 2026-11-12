@testable import Diduny
import Foundation
import Testing

/// `user_context` for Diduny Cloud (Soniox v6): clamped to the backend limits, omitted when empty.
@MainActor
struct SpeechUserContextTests {
    private static let pcm = RealtimeAudioConfig.defaultPCM16kMono

    @Test("Realtime config carries clamped user_context")
    func realtimeConfigClamps() throws {
        let context = SpeechUserContext(
            domain: "  " + String(repeating: "d", count: 250) + "  ",
            text: String(repeating: "t", count: 3500),
            terms: [" GitHub ", "github", "", "   ", String(repeating: "x", count: 100)]
                + (0 ..< 400).map { "term\($0)" },
            translationTerms: [SpeechTranslationTerm(source: "реліз", target: "release")]
        )
        let config = CloudRealtimeService.makeConnectionConfig(
            languageHints: ["uk"], strictLanguageHints: true, audioConfig: Self.pcm,
            translationConfig: nil, enableSpeakerDiarization: false, userContext: context
        )
        let payload = try #require(config["user_context"] as? [String: Any])
        #expect((payload["domain"] as? String)?.count == 200)
        #expect((payload["text"] as? String)?.count == 3000)
        let terms = try #require(payload["terms"] as? [String])
        #expect(terms.count == 300)
        #expect(terms.first == "GitHub")
        #expect(terms[1] == String(repeating: "x", count: 80))
        #expect(!terms.contains("github"))
        // Not a translation: no glossary.
        #expect(payload["translation_terms"] == nil)
    }

    @Test("Realtime translation config carries the glossary")
    func realtimeTranslationGlossary() throws {
        let pairs = [SpeechTranslationTerm(source: " реліз ", target: "release"),
                     SpeechTranslationTerm(source: "Реліз", target: "duplicate"),
                     SpeechTranslationTerm(source: "empty", target: " ")]
            + (0 ..< 250).map { SpeechTranslationTerm(source: "s\($0)", target: "t\($0)") }
        let config = CloudRealtimeService.makeConnectionConfig(
            languageHints: [], strictLanguageHints: false, audioConfig: Self.pcm,
            translationConfig: RealtimeTranslationConfig(mode: .twoWay(languageA: "uk", languageB: "en")),
            enableSpeakerDiarization: false, userContext: SpeechUserContext(translationTerms: pairs)
        )
        let payload = try #require(config["user_context"] as? [String: Any])
        let glossary = try #require(payload["translation_terms"] as? [[String: String]])
        #expect(glossary.count == 200)
        #expect(glossary.first == ["source": "реліз", "target": "release"])
        #expect(payload["terms"] == nil)
    }

    @Test("Empty context omits user_context")
    func emptyOmitted() {
        let config = CloudRealtimeService.makeConnectionConfig(
            languageHints: [], strictLanguageHints: false, audioConfig: Self.pcm, translationConfig: nil,
            enableSpeakerDiarization: false,
            userContext: SpeechUserContext(domain: "  ", text: "", terms: [" ", ""],
                                           translationTerms: [SpeechTranslationTerm(source: "a", target: "b")])
        )
        #expect(config["user_context"] == nil)
        let noContext = CloudRealtimeService.makeConnectionConfig(
            languageHints: [], strictLanguageHints: false, audioConfig: Self.pcm, translationConfig: nil,
            enableSpeakerDiarization: false
        )
        #expect(noContext["user_context"] == nil)
    }

    @Test("Batch jobs config gets user_context; translation config also the glossary")
    func batchConfig() throws {
        let context = SpeechUserContext(domain: "payments", terms: ["WayForPay"],
                                        translationTerms: [SpeechTranslationTerm(source: "реліз", target: "release")])
        var transcribe = RecordingQueueService.buildCloudTranscriptionConfig(hints: ["uk"], enableSpeakerDiarization: true)
        context.apply(to: &transcribe)
        let payload = try #require(transcribe["user_context"] as? [String: Any])
        #expect(payload["domain"] as? String == "payments")
        #expect(payload["terms"] as? [String] == ["WayForPay"])
        #expect(payload["translation_terms"] == nil)

        var translate = CloudTranscriptionService.makeOneWayTranslationConfig(
            targetLanguage: "en", languageConfig: CloudLanguageConfig(hints: [], strict: false))
        context.apply(to: &translate)
        let translatePayload = try #require(translate["user_context"] as? [String: Any])
        #expect(translatePayload["translation_terms"] as? [[String: String]] == [["source": "реліз", "target": "release"]])

        var empty = RecordingQueueService.buildCloudTranscriptionConfig(hints: [], enableSpeakerDiarization: false)
        SpeechUserContext().apply(to: &empty)
        #expect(empty["user_context"] == nil)
    }

    @Test("From Settings: own terms, built-in names, then meeting attendees without email-only ones")
    func currentFromSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "SpeechUserContextTests.\(UUID().uuidString)"))
        let settings = SettingsStorage(defaults: defaults)
        settings.speechVocabularyTerms = ["Марінський"]
        settings.speechDomain = "macOS app"
        var meeting = CalendarMeeting(id: "m", calendarID: "work", title: "Weekly sync", start: Date(), end: Date())
        meeting.attendees = [CalendarAttendee(name: "Olena Petrenko"), CalendarAttendee(name: nil, email: "a@b.c"),
                             CalendarAttendee(name: "x@y.z")]

        let context = SpeechUserContext.current(calendarMeeting: meeting, settings: settings)
        #expect(context.domain == "macOS app")
        #expect(context.text == "Meeting: Weekly sync")
        #expect(context.terms.first == "Марінський")
        #expect(context.terms.contains("GitHub"))
        #expect(context.terms.last == "Olena Petrenko")
        #expect(!context.terms.contains("a@b.c") && !context.terms.contains("x@y.z"))

        settings.speechUsesCalendarContext = false
        let off = SpeechUserContext.current(calendarMeeting: meeting, settings: settings)
        #expect(off.text.isEmpty)
        #expect(!off.terms.contains("Olena Petrenko"))
    }
}
