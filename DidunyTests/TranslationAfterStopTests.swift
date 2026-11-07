@testable import Diduny
import Foundation
import Testing

/// Records which fake engine ran and what the Diduny text step was asked (WP-61, WP-62).
final class FakeQueueEngines: @unchecked Sendable, TextTranslationProtocol {
    var calls: [String] = []
    var translations: [String] = []
    var cloudConfigs: [[String: Any]] = []
    var translationFails = false

    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
        translations.append(targetLanguage)
        if translationFails { throw TranscriptionError.apiError("down") }
        return "[\(targetLanguage)] \(text)"
    }

    @MainActor var runner: QueueEngineRunner {
        QueueEngineRunner(
            cloud: { config in
                self.calls.append("cloud"); self.cloudConfigs.append(config)
                return GeneratedTranscript(text: "cloud text")
            },
            whisper: { self.calls.append("whisper"); return GeneratedTranscript(text: "whisper text") },
            whisperTranslateToEnglish: { self.calls.append("whisper-translate"); return "english" },
            onDevice: { id in self.calls.append(id); return "\(id) text" },
            elevenLabs: { diarize in
                self.calls.append(diarize ? "elevenlabs-diarize" : "elevenlabs")
                return GeneratedTranscript(text: "elevenlabs text")
            },
            translator: self
        )
    }
}

@MainActor
@Suite("Translation after Stop")
struct TranslationAfterStopTests {
    @Test("Whisper into a non-English target: Whisper transcribes, Diduny translates once into it (T1-TM-06)")
    func whisperNonEnglishTarget() async throws {
        let fakes = FakeQueueEngines()
        let result = try await fakes.runner.translate(.whisper, target: "uk", whisperModel: "ggml-large-v3")
        #expect(fakes.calls == ["whisper"])
        #expect(fakes.translations == ["uk"])
        #expect(result.text == "[uk] whisper text")
    }

    @Test("Turbo into English goes to the Diduny step, not Whisper's translate (bug 1)",
          arguments: ["ggml-large-v3-turbo", "ggml-large-v3-turbo-q5_0", "ggml-base.en"])
    func turboGoesToDidunyStep(model: String) async throws {
        let fakes = FakeQueueEngines()
        _ = try await fakes.runner.translate(.whisper, target: "en", whisperModel: model)
        #expect(fakes.calls == ["whisper"])
        #expect(fakes.translations == ["en"])
    }

    @Test("A model that translates gives Whisper's own English, no text step")
    func whisperOwnEnglish() async throws {
        let fakes = FakeQueueEngines()
        let result = try await fakes.runner.translate(.whisper, target: "en", whisperModel: "ggml-large-v3")
        #expect(fakes.calls == ["whisper-translate"])
        #expect(fakes.translations.isEmpty)
        #expect(result.text == "english")
    }

    @Test("ElevenLabs, Parakeet and Apple transcribe, then Diduny translates into the target (N11, N15)",
          arguments: [EngineID.elevenLabs, .parakeet, .appleSpeech])
    func ownEnginesThenDiduny(engine: EngineID) async throws {
        let fakes = FakeQueueEngines()
        let result = try await fakes.runner.translate(engine, target: "de", whisperModel: nil)
        #expect(fakes.calls.count == 1)
        #expect(fakes.translations == ["de"])
        #expect(result.text.hasPrefix("[de] "))
    }

    @Test("A failed text step throws instead of saving untranslated text as translated")
    func failedStepThrows() async {
        let fakes = FakeQueueEngines()
        fakes.translationFails = true
        await #expect(throws: TranscriptionError.self) {
            _ = try await fakes.runner.translate(.elevenLabs, target: "uk", whisperModel: nil)
        }
    }

    @Test("Diduny Cloud translates the audio one way into the target")
    func cloudOneWay() async throws {
        let fakes = FakeQueueEngines()
        _ = try await fakes.runner.translate(.didunyCloud, target: "uk", whisperModel: nil)
        #expect(fakes.calls == ["cloud"])
        #expect(fakes.translations.isEmpty)
        let translation = try #require(fakes.cloudConfigs.first?["translation"] as? [String: Any])
        #expect(translation["target_language"] as? String == "uk")
    }

    @Test("Translating never writes the stored target (bug 2)")
    @MainActor
    func storedTargetUntouched() async throws {
        let before = SettingsStorage.shared.voiceTranslationTargetLanguage
        let fakes = FakeQueueEngines()
        _ = try await fakes.runner.translate(.whisper, target: "de", whisperModel: "ggml-large-v3-turbo")
        _ = try await fakes.runner.translate(.whisper, target: "en", whisperModel: "ggml-large-v3")
        #expect(SettingsStorage.shared.voiceTranslationTargetLanguage == before)
    }

    @Test("Translate meeting on ElevenLabs records only and translates after Stop (10A)",
          arguments: [EngineID.elevenLabs, .whisper, .parakeet, .appleSpeech])
    func meetingTranslationAfterStop(engine: EngineID) {
        let route = RunTimeRoute(engine: engine, modelID: nil, unavailable: nil, baseProvider: .local)
        let start = RunTimeRouting.meetingTranslationAfterStop(route)
        #expect(start.engine == engine)
        #expect(start.provider == .local)
        #expect(!start.localPreview)
        #expect(start.afterStopEngineID == route.onDeviceEngineID)
    }

    @Test("Signed out, Whisper alone cannot reach a non-English target (7A)")
    func signedOutRefuses() {
        #expect(RunTimeRouting.localTranslation(model: "ggml-large-v3", target: "uk", signedIn: false) == .signInNeeded)
        #expect(RunTimeRouting.localTranslation(model: "ggml-large-v3-turbo", target: "en", signedIn: true) == .didunyStep)
        #expect(RunTimeRouting.localTranslation(model: "ggml-large-v3", target: "en", signedIn: false) == .whisper)
    }
}
