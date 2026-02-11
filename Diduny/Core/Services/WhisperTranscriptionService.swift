import Foundation

final class WhisperTranscriptionService: TranscriptionServiceProtocol {
    var apiKey: String? // Unused for local transcription, required by protocol
    var modelNameOverride: String?

    private var whisperContext: WhisperContext?
    private var loadedModelPath: String?

    func transcribe(audioData: Data) async throws -> String {
        let context = try await ensureContext()
        let samples = try AudioConverter.convertToWhisperFormat(audioData: audioData)

        guard !samples.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        let settings = SettingsStorage.shared
        let language = settings.whisperLanguage.isEmpty || settings.whisperLanguage == "auto" ? nil : settings.whisperLanguage
        let prompt = settings.whisperPrompt.isEmpty ? nil : settings.whisperPrompt

        let text = try await context.transcribe(samples: samples, language: language, initialPrompt: prompt)

        guard !text.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        return text
    }

    func transcribeRawSamples(_ samples: [Float]) async throws -> String {
        let context = try await ensureContext()
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }
        // Ambient listening uses minimal settings — no language/prompt override
        return try await context.transcribe(samples: samples)
    }

    func translateAndTranscribe(audioData: Data) async throws -> String {
        // Whisper can only translate TO English, not bidirectional like Soniox
        Log.whisper.warning("Translation requested but Whisper only supports translate-to-English. Using plain transcription.")
        return try await transcribe(audioData: audioData)
    }

    func translateAndTranscribe(audioData: Data, targetLanguage: String) async throws -> String {
        // Whisper ignores target language — it can only translate to English
        Log.whisper.warning("Translation to \(targetLanguage) requested but Whisper only supports translate-to-English. Using plain transcription.")
        return try await transcribe(audioData: audioData)
    }

    // MARK: - Private

    private func ensureContext() async throws -> WhisperContext {
        let model: WhisperModelManager.WhisperModel

        if let overrideName = modelNameOverride,
           let overrideModel = WhisperModelManager.availableModels.first(where: { $0.name == overrideName }),
           WhisperModelManager.shared.isModelDownloaded(overrideModel)
        {
            model = overrideModel
        } else if let selectedModel = WhisperModelManager.shared.selectedModel() {
            model = selectedModel
        } else {
            throw WhisperError.modelNotFound
        }

        let path = WhisperModelManager.shared.modelPath(for: model)

        // Reuse context if same model
        if let context = whisperContext, loadedModelPath == path {
            return context
        }

        // Load new context
        Log.whisper.info("Loading Whisper model: \(model.displayName)")
        let context = try WhisperContext(modelPath: path)
        whisperContext = context
        loadedModelPath = path
        return context
    }
}
