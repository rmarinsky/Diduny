@testable import Diduny
import XCTest

final class VoiceTranslationTests: XCTestCase {
    func test_mixedSpeechPreservesTargetLanguageWordsInOrder() async {
        let accumulator = RealtimeTranslationAccumulator(targetLanguage: "en")
        await accumulator.process(tokens: [
            RealtimeToken(text: "Ready. ", isFinal: true, language: "en", translationStatus: "none"),
            RealtimeToken(text: "Я обираю режим ", isFinal: true, language: "uk", translationStatus: "original"),
            RealtimeToken(
                text: "I choose ",
                isFinal: true,
                language: "en",
                sourceLanguage: "uk",
                translationStatus: "translation"
            ),
            RealtimeToken(text: "translate.", isFinal: true, language: "en", translationStatus: "none")
        ])

        let text = await accumulator.bestText(includeProvisional: false)
        XCTAssertEqual(text, "Ready. I choose translate.")
    }

    func test_outputDoesNotFallBackToAnotherLanguage() async {
        let accumulator = RealtimeTranslationAccumulator(targetLanguage: "en")
        await accumulator.process(tokens: [
            RealtimeToken(text: "Я обираю режим", isFinal: true, language: "uk", translationStatus: "original"),
            RealtimeToken(text: " перекладу", isFinal: true, language: "uk", translationStatus: "translation"),
            RealtimeToken(text: " тест", isFinal: true, language: "uk", translationStatus: "none")
        ])

        let text = await accumulator.bestText()
        XCTAssertEqual(text, "")
    }

    func test_targetLanguageSpeechDoesNotRequireOptionalLanguageMetadata() async {
        let accumulator = RealtimeTranslationAccumulator(targetLanguage: "en")
        await accumulator.process(tokens: [
            RealtimeToken(text: "Keep the issue open.", isFinal: true, translationStatus: "none")
        ])

        let text = await accumulator.bestText(includeProvisional: false)
        XCTAssertEqual(text, "Keep the issue open.")
    }

    func test_latestProvisionalOutputReplacesThePreviousSnapshot() async {
        let accumulator = RealtimeTranslationAccumulator(targetLanguage: "en")
        await accumulator.process(tokens: [
            RealtimeToken(text: "I choose ", isFinal: true, language: "en", translationStatus: "translation"),
            RealtimeToken(text: "transit", isFinal: false, language: "en", translationStatus: "none")
        ])
        await accumulator.process(tokens: [
            RealtimeToken(text: "translate.", isFinal: false, language: "en", translationStatus: "none")
        ])
        let preview = await accumulator.bestText()
        let finalized = await accumulator.bestText(includeProvisional: false)
        XCTAssertEqual(preview, "I choose translate.")
        XCTAssertEqual(finalized, "I choose")

        await accumulator.process(tokens: [
            RealtimeToken(text: "translate.", isFinal: true, language: "en", translationStatus: "none")
        ])
        let completed = await accumulator.bestText()
        XCTAssertEqual(completed, "I choose translate.")
    }

    @MainActor
    func test_voiceFeedbackShowsOneOutputDirection() {
        let appDelegate = AppDelegate()
        appDelegate.activeTranslationLanguagePair = TranslationLanguagePair(languageA: "uk", languageB: "en")

        XCTAssertEqual(appDelegate.translationPairLabel, "→ EN")
        XCTAssertEqual(appDelegate.translationTargetLanguage, "en")
    }
}
