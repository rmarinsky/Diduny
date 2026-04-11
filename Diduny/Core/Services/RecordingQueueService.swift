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
            storage.updateRecording(id: item.id, status: .processing, error: nil)
        }

        pendingItems.append(contentsOf: newItems)
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
            let audioData = try Data(contentsOf: audioURL)

            let provider: TranscriptionProvider = if let override = item.providerOverride {
                override
            } else {
                switch item.action {
                case .transcribe, .transcribeDiarize:
                    SettingsStorage.shared.effectiveTranscriptionProvider
                case .translate:
                    SettingsStorage.shared.effectiveTranslationProvider
                }
            }

            let service = createTranscriptionService(
                for: provider,
                whisperModelOverride: item.whisperModelOverride
            )

            let text: String
            let status: Recording.ProcessingStatus
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
            case .translate:
                if let lang = item.targetLanguage {
                    text = try await service.translateAndTranscribe(audioData: audioData, targetLanguage: lang)
                } else {
                    text = try await service.translateAndTranscribe(audioData: audioData)
                }
                status = .translated
            }

            guard !Task.isCancelled else {
                storage.updateRecording(id: item.id, status: .unprocessed, error: nil)
                Log.app.info("Queue cancelled recording \(item.id)")
                return
            }

            storage.updateRecording(id: item.id, status: status, text: text, error: nil)
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
        let hints = SettingsStorage.shared.favoriteLanguages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var config: [String: Any] = ["mode": "transcribe"]
        if enableSpeakerDiarization {
            config["enable_speaker_diarization"] = true
        }
        if !hints.isEmpty {
            config["language_hints"] = hints
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
