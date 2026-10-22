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

    // MARK: - Output switching mid-recording

    func test_accumulatorKeepsSpokenWordsForSwitchingBackToOriginal() async {
        let accumulator = RealtimeTranslationAccumulator(targetLanguage: "en")
        await accumulator.process(tokens: [
            RealtimeToken(text: "Ready. ", isFinal: true, language: "en", translationStatus: "none"),
            RealtimeToken(text: "Я обираю ", isFinal: true, language: "uk", translationStatus: "original"),
            RealtimeToken(text: "I choose ", isFinal: true, language: "en", translationStatus: "translation"),
            RealtimeToken(text: "режим", isFinal: false, language: "uk", translationStatus: "original")
        ])

        let original = await accumulator.originalText()
        XCTAssertEqual(original, "Ready. Я обираю режим")
    }

    func test_accumulatorSpokenWordsExcludeEveryTranslationStatusThePanelHides() async {
        let accumulator = RealtimeTranslationAccumulator(targetLanguage: "en")
        await accumulator.process(tokens: [
            RealtimeToken(text: "Привіт", isFinal: true, language: "uk", translationStatus: "original"),
            RealtimeToken(text: " Hello", isFinal: true, language: "en", translationStatus: "translated"),
            RealtimeToken(text: " Hi", isFinal: true, language: "en", translationStatus: "target")
        ])

        let original = await accumulator.originalText()
        XCTAssertEqual(original, "Привіт")
    }

    func test_outputPlanKeepsNativeResultWhenSelectionIsUnchanged() {
        let plan = DictationOutput.translation(targetLanguage: "en").plan(
            native: .translation(targetLanguage: "en"),
            nativeText: "I choose",
            originalText: "Я обираю"
        )
        XCTAssertEqual(plan, .useAsIs("I choose"))
    }

    func test_outputPlanSwitchingTranslationToOriginalUsesSpokenWords() {
        let plan = DictationOutput.original.plan(
            native: .translation(targetLanguage: "en"),
            nativeText: "I choose",
            originalText: "Я обираю"
        )
        XCTAssertEqual(plan, .useAsIs("Я обираю"))
    }

    func test_outputPlanSwitchingToAnotherTargetTranslatesSpokenWords() {
        let fromDictation = DictationOutput.translation(targetLanguage: "de").plan(
            native: .original,
            nativeText: "Я обираю",
            originalText: "Я обираю"
        )
        let fromTranslation = DictationOutput.translation(targetLanguage: "de").plan(
            native: .translation(targetLanguage: "en"),
            nativeText: "I choose",
            originalText: "Я обираю"
        )
        XCTAssertEqual(fromDictation, .translate("Я обираю", to: "de"))
        XCTAssertEqual(fromTranslation, .translate("Я обираю", to: "de"))
    }

    func test_outputPlanWithoutSpokenWordsNeedsTheAudio() {
        let plan = DictationOutput.original.plan(
            native: .translation(targetLanguage: "en"),
            nativeText: "I choose",
            originalText: "  "
        )
        XCTAssertNil(plan)
    }

    func test_outputOptionsListOriginalThenPairLanguagesOnce() {
        let options = DictationOutput.options(
            pairs: [
                TranslationLanguagePair(languageA: "uk", languageB: "en"),
                TranslationLanguagePair(languageA: "en", languageB: "de")
            ],
            native: .translation(targetLanguage: "pl")
        )
        XCTAssertEqual(options, [
            .original,
            .translation(targetLanguage: "uk"),
            .translation(targetLanguage: "en"),
            .translation(targetLanguage: "de"),
            .translation(targetLanguage: "pl")
        ])
    }

    @MainActor
    func test_overlayShowsChosenOutputWithoutRestartingTheStream() {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .voice)
        store.configureOutput(native: .original, options: [.original, .translation(targetLanguage: "en")])
        store.processTokens([RealtimeToken(text: "Привіт", isFinal: true)])

        store.selectedOutput = .translation(targetLanguage: "en")
        XCTAssertEqual(store.title, "Translating")
        XCTAssertEqual(store.displayText, "Привіт")
        XCTAssertEqual(store.outputSourceText, "Привіт")

        store.convertedPreview = (output: .translation(targetLanguage: "en"), source: "Привіт", text: "Hello")
        XCTAssertEqual(store.displayText, "Hello")

        store.selectedOutput = .translation(targetLanguage: "de")
        XCTAssertEqual(store.displayText, "Привіт")

        store.selectedOutput = .original
        XCTAssertEqual(store.title, "Transcribing")
        XCTAssertEqual(store.displayText, "Привіт")
    }

    @MainActor
    func test_overlaySwitchingTranslationToOriginalShowsSpokenWords() {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .translation(targetLanguage: "→ EN"))
        store.configureOutput(
            native: .translation(targetLanguage: "en"),
            options: [.original, .translation(targetLanguage: "en")]
        )
        store.processTokens([
            RealtimeToken(text: "Привіт", isFinal: true, language: "uk", translationStatus: "original"),
            RealtimeToken(text: "Hello", isFinal: true, language: "en", translationStatus: "translation")
        ])
        XCTAssertEqual(store.displayText, "Hello")

        store.selectedOutput = .original
        XCTAssertEqual(store.displayText, "Привіт")
        XCTAssertNil(store.outputSourceText)
        store.finalText = "Привіт!"
        store.phase = .pasted
        XCTAssertEqual(store.displayText, "Привіт!")
    }
}
