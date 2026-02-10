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
        whisperModelOverride: String? = nil
    ) {
        guard !ids.isEmpty else { return }

        // Mark all as processing in storage
        let storage = RecordingsLibraryStorage.shared
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
                    whisperModelOverride: whisperModelOverride
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
        isProcessing = false
        currentRecordingId = nil
        queueCount = 0
    }

    private func processRecording(
        id: UUID,
        action: QueueAction,
        providerOverride: TranscriptionProvider? = nil,
        whisperModelOverride: String? = nil
    ) async {
        let storage = RecordingsLibraryStorage.shared

        guard let recording = storage.recordings.first(where: { $0.id == id }) else { return }

        let audioURL = storage.audioFileURL(for: recording)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            storage.updateRecording(id: id, status: .failed, error: "Audio file not found")
            return
        }

        do {
            let audioData = try Data(contentsOf: audioURL)

            // Determine provider: use override if provided, otherwise global setting
            let provider: TranscriptionProvider
            if let override = providerOverride {
                provider = override
            } else {
                provider = action == .transcribe
                    ? SettingsStorage.shared.transcriptionProvider
                    : SettingsStorage.shared.translationProvider
            }

            // Create fresh service instance
            var service = createTranscriptionService(
                for: provider,
                whisperModelOverride: whisperModelOverride
            )

            // Set API key if using Soniox
            if provider == .soniox {
                guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                    storage.updateRecording(id: id, status: .failed, error: "No API key configured")
                    return
                }
                service.apiKey = apiKey
            }

            let text: String
            let status: Recording.ProcessingStatus
            switch action {
            case .transcribe:
                text = try await service.transcribe(audioData: audioData)
                status = .transcribed
            case .translate:
                text = try await service.translateAndTranscribe(audioData: audioData)
                status = .translated
            }

            storage.updateRecording(id: id, status: status, text: text)
            Log.app.info("Queue processed recording \(id): \(status.rawValue)")

        } catch {
            storage.updateRecording(id: id, status: .failed, error: error.localizedDescription)
            Log.app.error("Queue failed for recording \(id): \(error.localizedDescription)")
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
