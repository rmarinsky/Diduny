import Foundation

/// Runs one queue item on a named engine (WP-61, WP-62). Record only and Translate meeting pass the engine
/// the meeting ran; engines that cannot translate themselves transcribe, then the Diduny text step
/// translates into one target. The closures are the engines; tests pass fakes.
@MainActor
struct QueueEngineRunner {
    /// Diduny Cloud batch through the jobs API with this config.
    var cloud: (_ config: [String: Any]) async throws -> GeneratedTranscript
    var whisper: () async throws -> GeneratedTranscript
    /// Whisper's own translation into English.
    var whisperTranslateToEnglish: () async throws -> String
    /// Parakeet V3 or Apple Speech on this Mac.
    var onDevice: (_ engineID: String) async throws -> String
    var elevenLabs: (_ diarize: Bool) async throws -> GeneratedTranscript
    var translator: TextTranslationProtocol

    func transcribe(_ engine: EngineID, diarize: Bool, hints: [String]) async throws -> GeneratedTranscript {
        switch engine {
        case .didunyCloud:
            try await cloud(RecordingQueueService.buildCloudTranscriptionConfig(hints: hints, enableSpeakerDiarization: diarize))
        case .elevenLabs:
            try await elevenLabs(diarize)
        case .whisper:
            try await whisper()
        case .parakeet, .appleSpeech:
            try await GeneratedTranscript(text: onDevice(engine.rawValue))
        }
    }

    /// Translation into `target` only, one direction (T1-TM-06). Diduny Cloud translates the audio; Whisper
    /// itself only into English on a model that can (bugs 1, 3); every other case transcribes, then Diduny
    /// translates the text. A failed text step throws, so the recording is not saved as translated.
    func translate(_ engine: EngineID, target: String, whisperModel: String?) async throws -> GeneratedTranscript {
        if engine == .didunyCloud {
            return try await cloud(CloudTranscriptionService.makeOneWayTranslationConfig(
                targetLanguage: target, languageConfig: CloudTranscriptionService.resolveLanguageConfig()))
        }
        if engine == .whisper, JobRequest.whisperTranslationUsable(model: whisperModel, target: target) {
            return try await GeneratedTranscript(text: whisperTranslateToEnglish())
        }
        let original = try await transcribe(engine, diarize: false, hints: [])
        let step = await ByokTranslationStep.translate(original.text, targetLanguage: target, translator: translator)
        guard step.translated else {
            throw TranscriptionError.apiError(String(localized: "Translation failed. Try again from the recording."))
        }
        return GeneratedTranscript(text: step.text)
    }
}
