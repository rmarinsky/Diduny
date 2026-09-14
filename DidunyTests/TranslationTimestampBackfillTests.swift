@testable import Diduny
import Testing

struct TranslationTimestampBackfillTests {
    @Test("Translation tokens inherit startMs from preceding originals of the same speaker")
    func annotatesInterleavedTwoSpeakerBatch() {
        let backfill = TranslationTimestampBackfill()

        let tokens = [
            RealtimeToken(
                text: "Hello",
                isFinal: true,
                speaker: "1",
                startMs: 1200,
                endMs: 1400,
                translationStatus: "original"
            ),
            RealtimeToken(
                text: " there",
                isFinal: true,
                speaker: "1",
                startMs: 1400,
                endMs: 1600,
                translationStatus: "original"
            ),
            RealtimeToken(
                text: "Привіт",
                isFinal: true,
                speaker: "1",
                startMs: 0,
                endMs: 0,
                language: "uk",
                sourceLanguage: "en",
                translationStatus: "translation"
            ),
            RealtimeToken(
                text: "Hi",
                isFinal: true,
                speaker: "2",
                startMs: 5000,
                endMs: 5200,
                translationStatus: "original"
            ),
            RealtimeToken(
                text: "Привіт",
                isFinal: true,
                speaker: "2",
                startMs: 0,
                endMs: 0,
                language: "uk",
                sourceLanguage: "en",
                translationStatus: "translation"
            )
        ]

        let annotated = backfill.annotate(tokens)

        #expect(annotated.count == 5)
        #expect(annotated[0].startMs == 1200)
        #expect(annotated[1].startMs == 1400)
        #expect(annotated[2].text == "Привіт")
        #expect(annotated[2].startMs == 1200)
        #expect(annotated[2].endMs == 1200)
        #expect(annotated[2].speaker == "1")
        #expect(annotated[3].startMs == 5000)
        #expect(annotated[4].startMs == 5000)
        #expect(annotated[4].speaker == "2")
    }

    @Test("Translation without a matching speaker falls back to the last global original start")
    func fallsBackToLastGlobalStart() {
        let backfill = TranslationTimestampBackfill()

        let tokens = [
            RealtimeToken(
                text: "Hello",
                isFinal: true,
                speaker: "1",
                startMs: 3000,
                endMs: 3200,
                translationStatus: "original"
            ),
            RealtimeToken(
                text: "Привіт",
                isFinal: true,
                speaker: nil,
                startMs: 0,
                endMs: 0,
                translationStatus: "translation"
            )
        ]

        let annotated = backfill.annotate(tokens)
        #expect(annotated[1].startMs == 3000)
    }

    @Test("reset clears tracked utterance starts so later translations do not reuse stale offsets")
    func resetClearsTracking() {
        let backfill = TranslationTimestampBackfill()

        _ = backfill.annotate([
            RealtimeToken(
                text: "Hello",
                isFinal: true,
                speaker: "1",
                startMs: 9000,
                endMs: 9100,
                translationStatus: "original"
            )
        ])
        backfill.reset()

        let annotated = backfill.annotate([
            RealtimeToken(
                text: "Привіт",
                isFinal: true,
                speaker: "1",
                startMs: 0,
                endMs: 0,
                translationStatus: "translation"
            )
        ])

        #expect(annotated[0].startMs == 0)
    }

    @Test("Non-translation tokens pass through unchanged")
    func originalsPassThrough() {
        let backfill = TranslationTimestampBackfill()
        let original = RealtimeToken(
            text: "Hello",
            isFinal: true,
            speaker: "1",
            startMs: 400,
            endMs: 500,
            translationStatus: "original"
        )

        let annotated = backfill.annotate([original])
        #expect(annotated[0] == original)
    }
}
