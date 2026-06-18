import Foundation

@Observable
@MainActor
final class RecordingQueueService {
    static let shared = RecordingQueueService()

    enum QueueAction {
        case transcribe
        case transcribeDiarize
        case translate
    }

    private(set) var isProcessing = false
    private(set) var currentRecordingId: UUID?
    private(set) var queueCount = 0
    private(set) var currentJobStatus: JobStatus?

    private struct QueueItem {
        let id: UUID
        let action: QueueAction
        let providerOverride: TranscriptionProvider?
        let whisperModelOverride: String?
        let targetLanguage: String?
    }

    private var processingTask: Task<Void, Never>?
    private var pendingItems: [QueueItem] = []
    private var currentItem: QueueItem?

    private init() {
        resetStaleProcessingStates()
    }

    func enqueue(
        _ ids: [UUID],
        action: QueueAction,
        providerOverride: TranscriptionProvider? = nil,
        whisperModelOverride: String? = nil,
        targetLanguage: String? = nil
    ) {
        guard !ids.isEmpty else { return }

        let storage = RecordingsLibraryStorage.shared
        let newItems = ids.compactMap { id in
            makeQueueItem(
                id: id,
                action: action,
                providerOverride: providerOverride,
                whisperModelOverride: whisperModelOverride,
                targetLanguage: targetLanguage
            )
        }
        guard !newItems.isEmpty else { return }

        for item in newItems {
            if let error = preflightError(for: item) {
                storage.updateRecording(id: item.id, status: .failed, error: error)
                continue
            }
            storage.updateRecording(id: item.id, status: .processing, error: nil)
            pendingItems.append(item)
        }

        refreshQueueState()
        startProcessingIfNeeded()
    }

    func cancelAll() {
        processingTask?.cancel()

        let idsToReset = Set(pendingItems.map(\.id) + [currentItem?.id].compactMap { $0 })
        let storage = RecordingsLibraryStorage.shared
        for id in idsToReset {
            storage.updateRecording(id: id, status: .unprocessed, error: nil)
        }

        pendingItems.removeAll()
        currentItem = nil
        refreshQueueState()
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        guard currentItem != nil || !pendingItems.isEmpty else { return }

        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.processPendingItems()
        }
    }

    private func processPendingItems() async {
        defer {
            processingTask = nil
            currentItem = nil
            refreshQueueState()
            startProcessingIfNeeded()
        }

        while !Task.isCancelled {
            guard !pendingItems.isEmpty else { break }

            currentItem = pendingItems.removeFirst()
            refreshQueueState()

            guard let item = currentItem else { continue }
            currentRecordingId = item.id
            currentJobStatus = nil

            await processRecording(item)

            currentItem = nil
            currentJobStatus = nil
            currentRecordingId = nil
            refreshQueueState()
        }
    }

    private func processRecording(_ item: QueueItem) async {
        let storage = RecordingsLibraryStorage.shared

        guard let recording = storage.recordings.first(where: { $0.id == item.id }) else {
            return
        }

        let audioURL = await storage.optimizeStoredRecordingIfNeeded(id: item.id) ?? storage.audioFileURL(for: recording)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            storage.updateRecording(id: item.id, status: .failed, error: "Audio file not found")
            return
        }

        do {
            let audioData = try await Task.detached(priority: .utility) {
                try Data(contentsOf: audioURL, options: .mappedIfSafe)
            }.value

            let provider = configuredProvider(for: item)

            if let error = preflightError(for: item, provider: provider) {
                storage.updateRecording(id: item.id, status: .failed, error: error)
                return
            }

            let service = createTranscriptionService(
                for: provider,
                whisperModelOverride: item.whisperModelOverride
            )

            let text: String
            let status: Recording.ProcessingStatus
            let translationTargetLanguageCode: String?
            switch item.action {
            case .transcribe:
                if provider == .cloud {
                    text = try await transcribeViaJobs(
                        audioData: audioData,
                        config: buildCloudTranscriptionConfig(enableSpeakerDiarization: false)
                    )
                } else {
                    text = try await service.transcribe(audioData: audioData)
                }
                status = .transcribed
                translationTargetLanguageCode = nil
            case .transcribeDiarize:
                if provider == .cloud {
                    text = try await transcribeViaJobs(
                        audioData: audioData,
                        config: buildCloudTranscriptionConfig(enableSpeakerDiarization: true)
                    )
                } else {
                    text = try await service.transcribe(audioData: audioData)
                }
                status = .transcribed
                translationTargetLanguageCode = nil
            case .translate:
                let targetLanguage: String
                if let explicitTargetLanguage = item.targetLanguage {
                    targetLanguage = explicitTargetLanguage
                    text = try await service.translateAndTranscribe(
                        audioData: audioData,
                        targetLanguage: explicitTargetLanguage
                    )
                } else {
                    let pair = SettingsStorage.shared.resolveTranslationLanguagePair()
                    targetLanguage = provider == .local ? "en" : pair.languageB
                    text = try await service.translateAndTranscribe(
                        audioData: audioData,
                        languagePair: pair
                    )
                }
                status = .translated
                translationTargetLanguageCode = targetLanguage
            }

            guard !Task.isCancelled else {
                storage.updateRecording(id: item.id, status: .unprocessed, error: nil)
                Log.app.info("Queue cancelled recording \(item.id)")
                return
            }

            storage.updateRecording(
                id: item.id,
                status: status,
                text: text,
                error: nil,
                translationTargetLanguageCode: translationTargetLanguageCode
            )
            currentJobStatus = nil
            Log.app.info("Queue processed recording \(item.id): \(status.rawValue)")
        } catch is CancellationError {
            storage.updateRecording(id: item.id, status: .unprocessed, error: nil)
            currentJobStatus = nil
            Log.app.info("Queue cancelled recording \(item.id)")
        } catch {
            storage.updateRecording(id: item.id, status: .failed, error: error.localizedDescription)
            currentJobStatus = nil
            Log.app.error("Queue failed for recording \(item.id): \(error.localizedDescription)")
        }
    }

    private func createTranscriptionService(
        for provider: TranscriptionProvider,
        whisperModelOverride: String? = nil
    ) -> TranscriptionServiceProtocol {
        switch provider {
        case .cloud:
            return CloudTranscriptionService()
        case .local:
            let service = WhisperTranscriptionService()
            service.modelNameOverride = whisperModelOverride
            return service
        }
    }

    private func buildCloudTranscriptionConfig(enableSpeakerDiarization: Bool) -> [String: Any] {
        let hints = SettingsStorage.shared.speechLanguageHints

        var config: [String: Any] = ["mode": "transcribe"]
        if enableSpeakerDiarization {
            config["enable_speaker_diarization"] = true
        }
        if !hints.isEmpty {
            config["language_hints"] = hints
            config["language_hints_strict"] = true
        }
        return config
    }

    private func transcribeViaJobs(audioData: Data, config: [String: Any]) async throws -> String {
        let asyncJobService = AsyncTranscriptionJobService()
        return try await asyncJobService.transcribeWithRetry(audioData: audioData, config: config) { [weak self] status in
            Task { @MainActor in
                self?.currentJobStatus = status
            }
        }
    }

    private func makeQueueItem(
        id: UUID,
        action: QueueAction,
        providerOverride: TranscriptionProvider?,
        whisperModelOverride: String?,
        targetLanguage: String?
    ) -> QueueItem? {
        guard currentItem?.id != id else {
            Log.app.info("Queue skipped duplicate active recording \(id)")
            return nil
        }

        guard !pendingItems.contains(where: { $0.id == id }) else {
            Log.app.info("Queue skipped duplicate pending recording \(id)")
            return nil
        }

        return QueueItem(
            id: id,
            action: action,
            providerOverride: providerOverride,
            whisperModelOverride: whisperModelOverride,
            targetLanguage: targetLanguage
        )
    }

    private func configuredProvider(for item: QueueItem) -> TranscriptionProvider {
        if let override = item.providerOverride {
            return override
        }

        switch item.action {
        case .transcribe, .transcribeDiarize:
            return SettingsStorage.shared.transcriptionProvider
        case .translate:
            return SettingsStorage.shared.translationProvider
        }
    }

    private func preflightError(for item: QueueItem) -> String? {
        preflightError(for: item, provider: configuredProvider(for: item))
    }

    private func preflightError(for item: QueueItem, provider: TranscriptionProvider) -> String? {
        switch provider {
        case .cloud:
            guard hasCloudCredentials else {
                return "Log in to use Cloud transcription."
            }
            return nil
        case .local:
            if item.action == .translate {
                let targetLanguage = item.targetLanguage
                    ?? SettingsStorage.shared.defaultTranslationLanguagePair.languageB
                if targetLanguage != "en",
                   item.targetLanguage != nil || !SettingsStorage.shared.defaultTranslationLanguagePair.contains("en") {
                    return "Local Whisper can translate to English only. Switch Translation Provider to Cloud or choose English."
                }
            }
            let modelName = item.whisperModelOverride ?? SettingsStorage.shared.selectedWhisperModel
            guard let model = WhisperModelManager.availableModels.first(where: { $0.name == modelName }),
                  WhisperModelManager.shared.isModelDownloaded(model)
            else {
                return "No local Whisper model downloaded. Log in for Cloud or download a model in Settings."
            }
            return nil
        }
    }

    private var hasCloudCredentials: Bool {
        #if TEST_BUILD
            if let token = ProcessInfo.processInfo.environment["DIDUNY_E2E_ACCESS_TOKEN"],
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
        #endif
        return AuthService.hasStoredSession
    }

    private func refreshQueueState() {
        isProcessing = currentItem != nil || !pendingItems.isEmpty
        currentRecordingId = currentItem?.id
        queueCount = pendingItems.count
        if currentItem == nil {
            currentJobStatus = nil
        }
    }

    private func resetStaleProcessingStates() {
        let storage = RecordingsLibraryStorage.shared
        for recording in storage.recordings where recording.status == .processing {
            storage.updateRecording(id: recording.id, status: .unprocessed, error: nil)
        }
    }
}
