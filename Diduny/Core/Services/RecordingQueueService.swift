import Foundation

@Observable
@MainActor
final class RecordingQueueService {
    static let shared = RecordingQueueService()

    enum QueueAction {
        case transcribe
        case translate
    }

    private(set) var isProcessing = false
    private(set) var currentRecordingId: UUID?
    private(set) var queueCount = 0

    private var processingTask: Task<Void, Never>?

    private init() {}

    func enqueue(
        _ ids: [UUID],
        action: QueueAction,
        providerOverride: TranscriptionProvider? = nil,
        whisperModelOverride: String? = nil,
        targetLanguage: String? = nil
    ) {
        guard !ids.isEmpty else { return }

        // Reset any items left in processing state from cancelled task
        let storage = RecordingsLibraryStorage.shared
        for recording in storage.recordings where recording.status == .processing {
            storage.updateRecording(id: recording.id, status: .unprocessed)
        }

        // Mark all as processing in storage
        for id in ids {
            storage.updateRecording(id: id, status: .processing)
        }

        // Cancel any existing processing
        processingTask?.cancel()

        // Collect all IDs to process (existing queue items + new ones)
        let allIds = ids
        queueCount = allIds.count
        isProcessing = true

        processingTask = Task {
            for id in allIds {
                guard !Task.isCancelled else { break }
                currentRecordingId = id
                await processRecording(
                    id: id,
                    action: action,
                    providerOverride: providerOverride,
                    whisperModelOverride: whisperModelOverride,
                    targetLanguage: targetLanguage
                )
                queueCount -= 1
            }
            isProcessing = false
            currentRecordingId = nil
            queueCount = 0
        }
    }

    func cancelAll() {
        processingTask?.cancel()
        processingTask = nil
        // Reset any recordings left in processing state
        let storage = RecordingsLibraryStorage.shared
        for recording in storage.recordings where recording.status == .processing {
            storage.updateRecording(id: recording.id, status: .unprocessed)
        }
        isProcessing = false
        currentRecordingId = nil
        queueCount = 0
    }

    private func processRecording(
        id: UUID,
        action: QueueAction,
        providerOverride: TranscriptionProvider? = nil,
        whisperModelOverride: String? = nil,
        targetLanguage: String? = nil
    ) async {
        await RecordingDebugScope.$recordingID.withValue(id) {
            let storage = RecordingsLibraryStorage.shared
            RecordingDebugLog.app("Queue processing started (\(action))", source: "Queue")

            guard let recording = storage.recordings.first(where: { $0.id == id }) else {
                RecordingDebugLog.app("Recording not found in storage", source: "Queue")
                return
            }

            let audioURL = storage.audioFileURL(for: recording)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                storage.updateRecording(id: id, status: .failed, error: "Audio file not found")
                RecordingDebugLog.app("Audio file missing: \(audioURL.lastPathComponent)", source: "Queue")
                return
            }

            do {
                let audioData = try Data(contentsOf: audioURL)

                // Determine provider: translate always uses Soniox; transcribe uses override or global setting
                let provider: TranscriptionProvider
                if action == .translate {
                    provider = .soniox
                } else if let override = providerOverride {
                    provider = override
                } else {
                    provider = SettingsStorage.shared.transcriptionProvider
                }

                RecordingDebugLog.decision(
                    "action=\(String(describing: action)) provider=\(provider.rawValue) targetLanguage=\(targetLanguage ?? "none")",
                    source: "Queue"
                )

                // Create fresh service instance
                var service = createTranscriptionService(
                    for: provider,
                    whisperModelOverride: whisperModelOverride
                )

                // Set API key if using Soniox
                if provider == .soniox {
                    guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
                        storage.updateRecording(id: id, status: .failed, error: "No API key configured")
                        RecordingDebugLog.app("Missing Soniox API key", source: "Queue")
                        return
                    }
                    service.apiKey = apiKey
                }

                let text: String
                let status: Recording.ProcessingStatus
                switch action {
                case .transcribe:
                    if provider == .soniox,
                       recording.type == .meeting,
                       let sonioxService = service as? SonioxTranscriptionService
                    {
                        RecordingDebugLog.decision(
                            "Meeting transcription path: Soniox diarization enabled",
                            source: "Queue"
                        )
                        text = try await sonioxService.transcribeMeeting(audioData: audioData)
                    } else {
                        text = try await service.transcribe(audioData: audioData)
                    }
                    status = .transcribed
                case .translate:
                    if let lang = targetLanguage {
                        text = try await service.translateAndTranscribe(audioData: audioData, targetLanguage: lang)
                    } else {
                        text = try await service.translateAndTranscribe(audioData: audioData)
                    }
                    status = .translated
                }

                storage.updateRecording(id: id, status: status, text: text)
                Log.app.info("Queue processed recording \(id): \(status.rawValue)")
                RecordingDebugLog.app(
                    "Queue processing finished: status=\(status.rawValue), chars=\(text.count)",
                    source: "Queue"
                )
            } catch {
                storage.updateRecording(id: id, status: .failed, error: error.localizedDescription)
                Log.app.error("Queue failed for recording \(id): \(error.localizedDescription)")
                RecordingDebugLog.app("Queue processing failed: \(error.localizedDescription)", source: "Queue")
            }
        }
    }

    private func createTranscriptionService(
        for provider: TranscriptionProvider,
        whisperModelOverride: String? = nil
    ) -> TranscriptionServiceProtocol {
        switch provider {
        case .soniox:
            return SonioxTranscriptionService()
        case .whisperLocal:
            let service = WhisperTranscriptionService()
            service.modelNameOverride = whisperModelOverride
            return service
        }
    }
}
