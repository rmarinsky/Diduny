import Foundation

final class WhisperTranscriptionService: TranscriptionServiceProtocol {
    var modelNameOverride: String?

    private var whisperContext: WhisperContext?
    private var loadedModelPath: String?

    private var unloadTask: Task<Void, Never>?
    private var policyObserver: NSObjectProtocol?

    init() {
        policyObserver = NotificationCenter.default.addObserver(
            forName: .whisperModelUnloadPolicyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePolicyChange()
        }
    }

    deinit {
        unloadTask?.cancel()
        if let observer = policyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func transcribe(audioData: Data) async throws -> String {
        try await performTranscription(audioData: audioData, translate: false)
    }

    func transcribeRawSamples(_ samples: [Float]) async throws -> String {
        cancelUnloadTimer()
        defer { scheduleModelUnload() }

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
            Log.whisper.warning("Whisper can only translate to English, target language '\(targetLanguage)' rejected")
            throw WhisperError.unsupportedTranslationTarget(targetLanguage)
        }
        return try await translateAndTranscribe(audioData: audioData)
    }

    func translateAndTranscribe(audioData: Data, languagePair: TranslationLanguagePair) async throws -> String {
        guard languagePair.contains("en") else {
            throw WhisperError.unsupportedTranslationTarget(languagePair.displayLabel)
        }
        return try await translateAndTranscribe(audioData: audioData, targetLanguage: "en")
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
        cancelUnloadTimer()
        defer { scheduleModelUnload() }

        let context = try await ensureContext()
        let samples = try AudioConverter.convertToWhisperFormat(audioData: audioData)

        guard !samples.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        let settings = SettingsStorage.shared
        let language = settings.whisperLanguage.isEmpty || settings.whisperLanguage == "auto" ? nil : settings
            .whisperLanguage
        let prompt = ProtectedLexiconPromptBuilder.mergedPrompt(
            userPrompt: settings.whisperPrompt,
            language: language
        )

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

    // MARK: - Model Unload Timer

    private func cancelUnloadTimer() {
        unloadTask?.cancel()
        unloadTask = nil
    }

    private func scheduleModelUnload() {
        guard whisperContext != nil else { return }

        guard let interval = SettingsStorage.shared.whisperModelUnloadPolicy.timeInterval else {
            return // keepLoaded — no timer
        }

        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.unloadModel()
        }
    }

    private func unloadModel() {
        guard whisperContext != nil else { return }
        whisperContext = nil
        loadedModelPath = nil
        Log.whisper.info("Whisper model unloaded after inactivity timeout")
    }

    private func handlePolicyChange() {
        guard whisperContext != nil else { return }
        cancelUnloadTimer()
        scheduleModelUnload()
    }
}
