@testable import Diduny
import Testing

/// Live Translate meeting transcript: originals kept, a speaker and direction per turn, token order (T1-TM-05).
struct TranslateMeetingTranscriptTests {
    let pair = TranslationLanguagePair(languageA: "en", languageB: "uk")

    func original(_ text: String, speaker: String?, language: String, final: Bool = true) -> RealtimeToken {
        RealtimeToken(text: text, isFinal: final, speaker: speaker, language: language, translationStatus: "original")
    }

    func translated(_ text: String, speaker: String? = nil, into language: String, from source: String, final: Bool = true) -> RealtimeToken {
        RealtimeToken(
            text: text, isFinal: final, speaker: speaker, language: language,
            sourceLanguage: source, translationStatus: "translation"
        )
    }

    @Test("Two speakers in two languages: direction labels, originals and translations in token order")
    func directionsAndOriginals() {
        var transcript = TranslateMeetingTranscript(pair: pair)
        transcript.process([
            original("Привіт", speaker: "1", language: "uk"),
            translated("Hello", into: "en", from: "uk"),
            original("Thanks", speaker: "2", language: "en"),
            translated("Дякую", into: "uk", from: "en"),
        ])

        let turns = transcript.turns
        #expect(turns.map(\.label) == ["Speaker 1 · UK → EN", "Speaker 2 · EN → UK"])
        #expect(turns.map(\.original) == ["Привіт", "Thanks"])
        #expect(turns.map(\.translation) == ["Hello", "Дякую"])
    }

    @Test("Translated tokens without a speaker keep the turn's speaker")
    func translationKeepsSpeaker() {
        var transcript = TranslateMeetingTranscript(pair: pair)
        transcript.process([original("Привіт", speaker: "1", language: "uk"), translated("Hello", into: "en", from: "uk")])
        #expect(transcript.turns.count == 1)
        #expect(transcript.turns.first?.speaker == "1")
    }

    @Test("An original after translated text opens a new turn for the same speaker")
    func nextUtteranceSameSpeaker() {
        var transcript = TranslateMeetingTranscript(pair: pair)
        transcript.process([
            original("Раз", speaker: "1", language: "uk"),
            translated("One", into: "en", from: "uk"),
            original("Два", speaker: "1", language: "uk"),
        ])
        #expect(transcript.turns.map(\.original) == ["Раз", "Два"])
    }

    @Test("The shown language falls back to the other language of the pair")
    func shownLanguageFromPair() {
        var transcript = TranslateMeetingTranscript(pair: pair)
        transcript.process([original("Hi", speaker: "1", language: "en")])
        #expect(transcript.turns.first?.label == "Speaker 1 · EN → UK")
    }

    @Test("Provisional tokens are replaced by the next batch and cleared by finals")
    func provisionalTail() {
        var transcript = TranslateMeetingTranscript(pair: pair)
        transcript.process([original("Hel", speaker: "1", language: "en", final: false)])
        #expect(transcript.turns.first?.original == "Hel")
        transcript.process([original("Hello", speaker: "1", language: "en", final: false)])
        #expect(transcript.turns.first?.original == "Hello")
        transcript.process([original("Hello", speaker: "1", language: "en")])
        #expect(transcript.turns.map(\.original) == ["Hello"])
    }

    @Test("Copy text has the translations with their labels, no originals")
    func translationText() {
        var transcript = TranslateMeetingTranscript(pair: pair)
        transcript.process([original("Привіт", speaker: "1", language: "uk"), translated("Hello", into: "en", from: "uk")])
        #expect(transcript.translationText == "Speaker 1 · UK → EN\nHello")
    }
}
