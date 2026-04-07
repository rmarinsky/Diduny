import Foundation

final class WhisperTranscriptionService: TranscriptionServiceProtocol {
    var modelNameOverride: String?

    private var whisperContext: WhisperContext?
    private var loadedModelPath: String?

    func transcribe(audioData: Data) async throws -> String {
        try await performTranscription(audioData: audioData, translate: false)
    }

    func transcribeRawSamples(_ samples: [Float]) async throws -> String {
        let context = try await ensureContext()
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }
        return try await context.transcribe(samples: samples)
    }

    func translateAndTranscribe(audioData: Data) async throws -> String {
        try validateModelSupportsTranslation()
        return try await performTranscription(audioData: audioData, translate: true)
    }

    func translateAndTranscribe(audioData: Data, targetLanguage: String) async throws -> String {
        if targetLanguage.lowercased() != "en" {
            Log.whisper.warning("Whisper can only translate to English, ignoring target language '\(targetLanguage)'")
            return try await transcribe(audioData: audioData)
        }
        return try await translateAndTranscribe(audioData: audioData)
    }

    // MARK: - Translation Validation

    private func validateModelSupportsTranslation() throws {
        guard let model = WhisperModelManager.shared.selectedModel() else {
            throw WhisperError.modelNotFound
        }
        if model.isEnglishOnly {
            throw WhisperError.modelDoesNotSupportTranslation
        }
    }

    // MARK: - Private

    private func performTranscription(audioData: Data, translate: Bool) async throws -> String {
        let context = try await ensureContext()
        let samples = try AudioConverter.convertToWhisperFormat(audioData: audioData)

        guard !samples.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        let settings = SettingsStorage.shared
        let language = settings.whisperLanguage.isEmpty || settings.whisperLanguage == "auto" ? nil : settings
            .whisperLanguage
        let prompt = settings.whisperPrompt.isEmpty ? nil : settings.whisperPrompt

        let text = try await context.transcribe(
            samples: samples,
            language: language,
            initialPrompt: prompt,
            translate: translate
        )

        guard !text.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        return text
    }

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
