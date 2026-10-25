import Foundation

final class WhisperTranscriptionService: TranscriptionServiceProtocol {
    var modelNameOverride: String?

    /// Guards the loaded context, the in-flight load and the recording hold:
    /// preload, live preview and the final transcription reach them from
    /// different tasks.
    private let stateLock = NSLock()
    private var whisperContext: WhisperContext?
    private var loadedModelPath: String?
    private var pendingLoad: (path: String, task: Task<WhisperContext, Error>)?
    private var isHeldForRecording = false

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

    /// Starts loading the model when a recording starts, so Stop only waits for
    /// transcription. The unload timer stays off until `endRecordingHold()`.
    func beginRecordingHold() {
        stateLock.withLock { isHeldForRecording = true }
        cancelUnloadTimer()
        Task { [weak self] in
            do {
                _ = try await self?.ensureContext()
            } catch {
                Log.whisper.warning("Whisper preload failed: \(error.localizedDescription)")
            }
        }
    }

    func endRecordingHold() {
        let wasHeld = stateLock.withLock {
            defer { isHeldForRecording = false }
            return isHeldForRecording
        }
        guard wasHeld else { return }
        scheduleModelUnload()
    }

    func transcribe(audioData: Data) async throws -> String {
        try await transcribeDetailed(audioData: audioData).text
    }

    func transcribeDetailed(audioData: Data) async throws -> GeneratedTranscript {
        try await performTranscription(audioData: audioData, translate: false)
    }

    func transcribeRawSamples(_ samples: [Float]) async throws -> String {
        try await transcribeRawSamplesDetailed(samples).text
    }

    private func transcribeRawSamplesDetailed(_ samples: [Float]) async throws -> GeneratedTranscript {
        cancelUnloadTimer()
        defer { scheduleModelUnload() }

        let context = try await ensureContext()
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        let (language, prompt) = transcriptionHints()
        return try await context.transcribe(
            samples: samples,
            language: language,
            initialPrompt: prompt
        )
    }

    func translateAndTranscribe(audioData: Data) async throws -> String {
        try validateModelSupportsTranslation()
        return try await performTranscription(audioData: audioData, translate: true).text
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

    private func performTranscription(audioData: Data, translate: Bool) async throws -> GeneratedTranscript {
        cancelUnloadTimer()
        defer { scheduleModelUnload() }

        let context = try await ensureContext()
        let samples = try AudioConverter.convertToWhisperFormat(audioData: audioData)

        guard !samples.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        let (language, prompt) = transcriptionHints()

        let started = Date()
        let transcript = try await context.transcribe(
            samples: samples,
            language: language,
            initialPrompt: prompt,
            translate: translate
        )
        Log.whisper.info("Whisper transcription took \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        guard !transcript.text.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        return transcript
    }

    private func transcriptionHints() -> (language: String?, prompt: String?) {
        let settings = SettingsStorage.shared
        let language = settings.whisperLanguage.isEmpty || settings.whisperLanguage == "auto"
            ? nil
            : settings.whisperLanguage
        return (
            language,
            ProtectedLexiconPromptBuilder.mergedPrompt(
                userPrompt: settings.whisperPrompt,
                language: language
            )
        )
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
        let displayName = model.displayName

        // Reuse the loaded context, or join a load already in flight for the same model
        let task: Task<WhisperContext, Error> = stateLock.withLock {
            if let context = whisperContext, loadedModelPath == path {
                return Task { context }
            }
            if let pendingLoad, pendingLoad.path == path {
                return pendingLoad.task
            }
            let task = Task.detached(priority: .userInitiated) {
                Log.whisper.info("Loading Whisper model: \(displayName)")
                let started = Date()
                let context = try WhisperContext(modelPath: path)
                Log.whisper.info("Whisper model loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                return context
            }
            pendingLoad = (path, task)
            return task
        }

        do {
            let context = try await task.value
            stateLock.withLock {
                if pendingLoad?.path == path {
                    pendingLoad = nil
                    whisperContext = context
                    loadedModelPath = path
                }
            }
            return context
        } catch {
            stateLock.withLock {
                if pendingLoad?.path == path { pendingLoad = nil }
            }
            throw error
        }
    }

    // MARK: - Model Unload Timer

    private func cancelUnloadTimer() {
        unloadTask?.cancel()
        unloadTask = nil
    }

    private func scheduleModelUnload() {
        let canUnload = stateLock.withLock { whisperContext != nil && !isHeldForRecording }
        guard canUnload else { return }

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
        let didUnload = stateLock.withLock {
            guard whisperContext != nil, !isHeldForRecording else { return false }
            whisperContext = nil
            loadedModelPath = nil
            return true
        }
        guard didUnload else { return }
        Log.whisper.info("Whisper model unloaded after inactivity timeout")
    }

    private func handlePolicyChange() {
        guard stateLock.withLock({ whisperContext != nil }) else { return }
        cancelUnloadTimer()
        scheduleModelUnload()
    }
}

actor LocalWhisperStreamingService {
    struct Configuration {
        let sampleRate: Int
        let windowDuration: TimeInterval
        let stepDuration: TimeInterval
        let rmsThreshold: Float
        let peakThreshold: Float

        static let compactPreview = Configuration(
            sampleRate: 16_000,
            windowDuration: 10,
            stepDuration: 3,
            rmsThreshold: 0.0025,
            peakThreshold: 0.015
        )
    }

    private let configuration: Configuration
    private let transcribe: @Sendable ([Float]) async throws -> String
    private let onText: @Sendable (String) async -> Void
    private let onError: @Sendable (Error) async -> Void

    private var samples: [Float] = []
    private var samplesSinceLastRun = 0
    private var inferenceTask: Task<Void, Never>?
    private var isStopped = false
    private var cumulativeText = ""

    init(
        configuration: Configuration = .compactPreview,
        transcribe: @escaping @Sendable ([Float]) async throws -> String,
        onText: @escaping @Sendable (String) async -> Void,
        onError: @escaping @Sendable (Error) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.transcribe = transcribe
        self.onText = onText
        self.onError = onError
    }

    func appendPCM16(_ data: Data) {
        guard !isStopped else { return }

        let newSamples = Self.floatSamples(fromPCM16: data)
        samples.append(contentsOf: newSamples)
        samplesSinceLastRun += newSamples.count

        let maximumSampleCount = Int(configuration.windowDuration * Double(configuration.sampleRate))
        if samples.count > maximumSampleCount {
            samples.removeFirst(samples.count - maximumSampleCount)
        }

        scheduleInferenceIfNeeded()
    }

    func waitUntilIdle() async {
        while let inferenceTask {
            await inferenceTask.value
        }
    }

    func stop() async {
        isStopped = true
        await waitUntilIdle()
        samples.removeAll(keepingCapacity: false)
    }

    private func scheduleInferenceIfNeeded() {
        let stepSampleCount = Int(configuration.stepDuration * Double(configuration.sampleRate))
        guard inferenceTask == nil, samplesSinceLastRun >= stepSampleCount else { return }

        samplesSinceLastRun = 0
        let recentSamples = samples.suffix(stepSampleCount)
        guard containsSpeech(recentSamples) else { return }

        let window = samples
        inferenceTask = Task { [transcribe] in
            do {
                let text = try await transcribe(window)
                await self.finishInference(text: text, error: nil)
            } catch {
                await self.finishInference(text: nil, error: error)
            }
        }
    }

    private func finishInference(text: String?, error: Error?) async {
        inferenceTask = nil
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let mergedText = mergeWithCumulativeText(text)
        {
            await onText(mergedText)
        } else if let error {
            await onError(error)
        }
        if !isStopped {
            scheduleInferenceIfNeeded()
        }
    }

    private func containsSpeech(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return false }
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let meanSquare = samples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(samples.count)
        return peak >= configuration.peakThreshold && sqrt(meanSquare) >= configuration.rmsThreshold
    }

    private func mergeWithCumulativeText(_ incomingText: String) -> String? {
        let incomingWords = incomingText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !incomingWords.isEmpty else { return nil }

        let existingWords = cumulativeText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !existingWords.isEmpty else {
            cumulativeText = incomingText
            return cumulativeText
        }

        // ponytail: exact word overlap is cheap for live preview; add fuzzy alignment only if
        // real model revisions still produce measurable duplicate phrases.
        let existingKeys = existingWords.map(Self.comparisonKey)
        let incomingKeys = incomingWords.map(Self.comparisonKey)
        if incomingKeys.count <= existingKeys.count,
           Array(existingKeys.suffix(incomingKeys.count)) == incomingKeys
        {
            return nil
        }

        var overlap = min(existingKeys.count, incomingKeys.count)
        while overlap >= 2,
              Array(existingKeys.suffix(overlap)) != Array(incomingKeys.prefix(overlap))
        {
            overlap -= 1
        }
        if overlap < 2 {
            overlap = 0
        }

        cumulativeText += " " + incomingWords.dropFirst(overlap).joined(separator: " ")
        return cumulativeText
    }

    private static func comparisonKey(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    private static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return [] }

        return stride(from: 0, to: bytes.count - 1, by: 2).map { index in
            let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            return Float(Int16(bitPattern: bits)) / 32_768
        }
    }
}
