import Foundation

@Observable
@MainActor
final class RecordingQueueService {
    static let shared = RecordingQueueService()

    enum QueueAction: Equatable {
        case transcribe
        case transcribeDiarize
        case translate
    }

    private(set) var isProcessing = false
    private(set) var currentRecordingId: UUID?
    private(set) var queueCount = 0
    private(set) var currentJobStatus: JobStatus?
    /// Stage and progress of the current item; nil between items.
    private(set) var currentProgress: QueueProgress?

    private struct QueueItem {
        let id: UUID
        let action: QueueAction
        let providerOverride: TranscriptionProvider?
        let whisperModelOverride: String?
        let targetLanguage: String?
        var localFallbackOnUsageLimit = false
    }

    private var processingTask: Task<Void, Never>?
    private var progressTickTask: Task<Void, Never>?
    private var lastProgressPublishedAt = Date.distantPast
    private var stageStartedAt = Date()
    private var pendingItems: [QueueItem] = []
    private var currentItem: QueueItem?
    private let storage: RecordingsLibraryStorage
    private let startsAutomatically: Bool
    private let hasSession: () -> Bool
    private let localModelIsAvailable: (String) -> Bool

    init(
        storage: RecordingsLibraryStorage? = nil,
        startsAutomatically: Bool = true,
        localModelIsAvailable: ((String) -> Bool)? = nil,
        hasSession: @escaping () -> Bool = { AuthService.hasStoredSession }
    ) {
        self.storage = storage ?? .shared
        self.startsAutomatically = startsAutomatically
        self.hasSession = hasSession
        self.localModelIsAvailable = localModelIsAvailable ?? { modelName in
            guard let model = WhisperModelManager.availableModels.first(where: { $0.name == modelName }) else {
                return false
            }
            return WhisperModelManager.shared.isModelDownloaded(model)
        }
        resetStaleProcessingStates()
    }

    /// Returns true when at least one recording was added to the queue.
    @discardableResult
    func enqueue(
        _ ids: [UUID],
        action: QueueAction,
        providerOverride: TranscriptionProvider? = nil,
        whisperModelOverride: String? = nil,
        targetLanguage: String? = nil,
        localFallbackOnUsageLimit: Bool = false
    ) -> Bool {
        guard !ids.isEmpty else { return false }

        let newItems = ids.compactMap { id in
            makeQueueItem(
                id: id,
                action: action,
                providerOverride: providerOverride,
                whisperModelOverride: whisperModelOverride,
                targetLanguage: targetLanguage,
                localFallbackOnUsageLimit: localFallbackOnUsageLimit
            )
        }
        guard !newItems.isEmpty else { return false }

        var admitted = false
        for item in newItems {
            if let error = preflightError(for: item) {
                storage.updateRecording(id: item.id, status: .failed, error: error)
                continue
            }
            storage.updateRecording(id: item.id, status: .processing, error: nil)
            pendingItems.append(item)
            admitted = true
        }

        refreshQueueState()
        startProcessingIfNeeded()
        return admitted
    }

    func cancelAll() {
        processingTask?.cancel()

        let idsToReset = Set(pendingItems.map(\.id) + [currentItem?.id].compactMap { $0 })
        for id in idsToReset {
            storage.updateRecording(id: id, status: .unprocessed, error: nil)
        }

        pendingItems.removeAll()
        currentItem = nil
        refreshQueueState()
    }

    private func startProcessingIfNeeded() {
        guard startsAutomatically else { return }
        guard processingTask == nil else { return }
        guard currentItem != nil || !pendingItems.isEmpty else { return }

        processingTask = Task { [weak self] in
            guard let self else { return }
            await processPendingItems()
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

            stopProgressTicks()
            currentItem = nil
            currentJobStatus = nil
            currentProgress = nil
            currentRecordingId = nil
            refreshQueueState()
        }
    }

    private func processRecording(_ item: QueueItem) async {
        guard let recording = storage.recordings.first(where: { $0.id == item.id }) else {
            return
        }
        let provider = configuredProvider(for: item)
        let totalSeconds = recording.effectiveDurationSeconds
        publishProgress(QueueProgress(stage: .preparing, provider: provider, totalSeconds: totalSeconds), itemID: item.id)

        let originalAudioURL = await storage.optimizeStoredRecordingIfNeeded(id: item.id) ?? storage
            .audioFileURL(for: recording)
        guard FileManager.default.fileExists(atPath: originalAudioURL.path) else {
            storage.updateRecording(id: item.id, status: .failed, error: String(localized: "Audio file not found"))
            return
        }

        do {
            let audioURL = try await AudioTrimService.prepareAudio(
                fileURL: originalAudioURL,
                range: recording.trimRange
            )
            defer {
                if audioURL != originalAudioURL { try? FileManager.default.removeItem(at: audioURL) }
            }
            try Task.checkCancellation()

            if let error = preflightError(for: item, provider: provider) {
                storage.updateRecording(id: item.id, status: .failed, error: error)
                return
            }

            let service = createTranscriptionService(
                for: provider,
                whisperModelOverride: item.whisperModelOverride
            )
            if let whisper = service as? WhisperTranscriptionService {
                whisper.onProgress = { [weak self] fraction in
                    Task { @MainActor in
                        self?.publishLocalProgress(fraction, totalSeconds: totalSeconds, itemID: item.id)
                    }
                }
            }

            var transcript: GeneratedTranscript
            let status: Recording.ProcessingStatus
            let translationTargetLanguageCode: String?
            let historyKind: TranscriptVersion.Kind
            let sourceLanguageCode: String?
            switch item.action {
            case .transcribe:
                if provider == .cloud {
                    transcript = try await transcribeViaJobs(
                        audioFileURL: audioURL,
                        config: buildCloudTranscriptionConfig(enableSpeakerDiarization: false),
                        source: recording.audioFileName,
                        sourceDurationSeconds: recording.effectiveDurationSeconds,
                        itemID: item.id
                    )
                } else {
                    let audioData = try await loadAudioData(from: audioURL)
                    transcript = try await service.transcribeDetailed(audioData: audioData)
                }
                status = .transcribed
                translationTargetLanguageCode = nil
                historyKind = provider == .local ? .local : .cloud
                sourceLanguageCode = nil
            case .transcribeDiarize:
                if provider == .cloud {
                    transcript = try await transcribeViaJobs(
                        audioFileURL: audioURL,
                        config: buildCloudTranscriptionConfig(enableSpeakerDiarization: true),
                        source: recording.audioFileName,
                        sourceDurationSeconds: recording.effectiveDurationSeconds,
                        itemID: item.id
                    )
                } else {
                    let audioData = try await loadAudioData(from: audioURL)
                    transcript = try await service.transcribeDetailed(audioData: audioData)
                }
                status = .transcribed
                translationTargetLanguageCode = nil
                historyKind = provider == .local ? .local : .cloud
                sourceLanguageCode = nil
            case .translate:
                let pair = SettingsStorage.shared.resolveTranslationLanguagePair()
                let targetLanguage: String
                if provider == .cloud {
                    // The synchronous POST path rejects large uploads (413) and
                    // times out on long meetings — cloud translation must go
                    // through the async jobs API, same as cloud transcription.
                    let config: [String: Any]
                    if let explicitTargetLanguage = item.targetLanguage {
                        targetLanguage = explicitTargetLanguage
                        config = CloudTranscriptionService.makeOneWayTranslationConfig(
                            targetLanguage: explicitTargetLanguage,
                            languageConfig: CloudTranscriptionService.resolveLanguageConfig()
                        )
                    } else {
                        targetLanguage = pair.languageB
                        config = CloudTranscriptionService.makeTwoWayTranslationConfig(
                            languagePair: pair,
                            languageConfig: CloudTranscriptionService.resolveLanguageConfig(
                                forcedLanguageHints: SettingsStorage.shared.translationLanguageHints(for: pair)
                            )
                        )
                    }
                    transcript = try await transcribeViaJobs(
                        audioFileURL: audioURL,
                        config: config,
                        source: recording.audioFileName,
                        sourceDurationSeconds: recording.effectiveDurationSeconds,
                        itemID: item.id
                    )
                } else {
                    let audioData = try await loadAudioData(from: audioURL)
                    if let explicitTargetLanguage = item.targetLanguage {
                        targetLanguage = explicitTargetLanguage
                        transcript = try await GeneratedTranscript(
                            text: service.translateAndTranscribe(
                                audioData: audioData,
                                targetLanguage: explicitTargetLanguage
                            )
                        )
                    } else {
                        targetLanguage = "en"
                        transcript = try await GeneratedTranscript(
                            text: service.translateAndTranscribe(
                                audioData: audioData,
                                languagePair: pair
                            )
                        )
                    }
                }
                status = .translated
                translationTargetLanguageCode = targetLanguage
                historyKind = .translation
                sourceLanguageCode = pair.languageA
            }

            if provider == .local, status == .transcribed {
                transcript = await LocalSpeakerLabelService.label(
                    transcript,
                    recording: recording,
                    tracksURL: storage.tracksFileURL(for: item.id),
                    audioURL: audioURL
                ) {
                    publishProgress(
                        QueueProgress(stage: .identifyingSpeakers, provider: provider, totalSeconds: totalSeconds),
                        itemID: item.id
                    )
                }
            }

            guard !Task.isCancelled else {
                storage.updateRecording(id: item.id, status: .unprocessed, error: nil)
                Log.app.info("Queue cancelled recording \(item.id)")
                return
            }

            stopProgressTicks()
            publishProgress(QueueProgress(stage: .finishing, provider: provider, totalSeconds: totalSeconds), itemID: item.id)

            let provenance = recording.remoteSource != nil && status == .transcribed
                ? GeneratedTranscriptProvenance(provider: provider.rawValue)
                : nil
            storage.completeTranscription(
                id: item.id,
                status: status,
                text: ClipboardService.preparedMessageText(transcript.text, recordingType: recording.type),
                segments: status == .transcribed && !transcript.segments.isEmpty
                    ? transcript.segments
                    : nil,
                translationTargetLanguageCode: translationTargetLanguageCode,
                generatedTranscriptProvenance: provenance,
                kind: historyKind,
                provider: provider.rawValue,
                modelIdentifier: provider == .local
                    ? item.whisperModelOverride ?? SettingsStorage.shared.selectedWhisperModel
                    : nil,
                sourceLanguageCode: sourceLanguageCode
            )
            currentJobStatus = nil
            Log.app.info("Queue processed recording \(item.id): \(status.rawValue)")
        } catch is CancellationError {
            storage.updateRecording(id: item.id, status: .unprocessed, error: nil)
            currentJobStatus = nil
            Log.app.info("Queue cancelled recording \(item.id)")
        } catch let error as TranscriptionError where Self.usageLimitFallbackProvider(
            for: error,
            provider: provider,
            allowsLocalFallback: item.localFallbackOnUsageLimit,
            hasLocalModel: localModelIsAvailable(SettingsStorage.shared.selectedWhisperModel)
        ) == .local {
            // Cloud ran out at Stop time: the meeting is transcribed on this Mac instead.
            let localItem = QueueItem(
                id: item.id,
                action: item.action,
                providerOverride: .local,
                whisperModelOverride: item.whisperModelOverride,
                targetLanguage: item.targetLanguage
            )
            pendingItems.insert(localItem, at: 0)
            currentJobStatus = nil
            Log.app.notice("Queue: cloud usage limit for \(item.id, privacy: .public), retrying on this Mac")
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

    private func transcribeViaJobs(
        audioFileURL: URL,
        config: [String: Any],
        source: String,
        sourceDurationSeconds: TimeInterval,
        itemID: UUID
    ) async throws -> GeneratedTranscript {
        let asyncJobService = AsyncTranscriptionJobService()
        return try await asyncJobService.transcribeFileDetailedWithRetry(
            audioFileURL: audioFileURL,
            config: config,
            source: source,
            sourceDurationSeconds: sourceDurationSeconds,
            onUploadProgress: { [weak self] fraction in
                Task { @MainActor in
                    self?.publishProgress(
                        QueueProgress(
                            stage: .uploading,
                            provider: .cloud,
                            totalSeconds: sourceDurationSeconds,
                            fraction: fraction
                        ),
                        itemID: itemID
                    )
                }
            }
        ) { [weak self] update in
            Task { @MainActor in
                self?.currentJobStatus = update.status
                self?.handleCloudJobStatus(update.status, totalSeconds: sourceDurationSeconds, itemID: itemID)
            }
        }
    }

    // MARK: - Progress

    /// Cloud fallback to Local applies only to items queued with it, only for the usage limit,
    /// and only when a local model is ready.
    nonisolated static func usageLimitFallbackProvider(
        for error: TranscriptionError,
        provider: TranscriptionProvider,
        allowsLocalFallback: Bool,
        hasLocalModel: Bool
    ) -> TranscriptionProvider? {
        guard error.isUsageLimitExceeded, provider == .cloud, allowsLocalFallback, hasLocalModel else { return nil }
        return .local
    }

    func isQueued(_ id: UUID) -> Bool {
        pendingItems.contains { $0.id == id }
    }

    private func handleCloudJobStatus(_ status: JobStatus, totalSeconds: TimeInterval, itemID: UUID) {
        // Status callbacks hop to the main actor and can arrive after the item finished.
        guard currentRecordingId == itemID else { return }
        switch status {
        case .queued, .processing:
            guard progressTickTask == nil, currentProgress?.stage != .finishing else { return }
            let estimate = CloudTranscriptionEstimate(audioSeconds: totalSeconds, startedAt: Date())
            progressTickTask = Task { [weak self] in
                while !Task.isCancelled, self?.currentRecordingId == itemID {
                    let now = Date()
                    let fraction = estimate.fraction(at: now)
                    self?.publishProgress(
                        QueueProgress(
                            stage: .transcribing,
                            provider: .cloud,
                            totalSeconds: totalSeconds,
                            fraction: fraction,
                            processedSeconds: fraction * totalSeconds,
                            secondsLeft: estimate.secondsLeft(at: now)
                        ),
                        itemID: itemID
                    )
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        case .finalizing:
            stopProgressTicks()
            publishProgress(QueueProgress(stage: .finishing, provider: .cloud, totalSeconds: totalSeconds), itemID: itemID)
        default:
            break
        }
    }

    private func publishLocalProgress(_ fraction: Double, totalSeconds: TimeInterval, itemID: UUID) {
        let elapsed = currentProgress?.stage == .transcribing ? Date().timeIntervalSince(stageStartedAt) : 0
        // Rate-based time left once there is enough progress to measure a rate.
        let secondsLeft: TimeInterval? = fraction >= 0.05 && fraction < 1 ? elapsed / fraction * (1 - fraction) : nil
        publishProgress(
            QueueProgress(
                stage: .transcribing,
                provider: .local,
                totalSeconds: totalSeconds,
                fraction: fraction,
                processedSeconds: fraction * totalSeconds,
                secondsLeft: secondsLeft
            ),
            itemID: itemID
        )
    }

    /// Publishes at most twice a second within a stage; stage changes always go through and are logged.
    private func publishProgress(_ progress: QueueProgress, itemID: UUID) {
        guard currentRecordingId == itemID else { return }
        // Stages only move forward within an item; a late upload event must not undo "Transcribing".
        if let current = currentProgress, progress.stage.order < current.stage.order { return }
        let now = Date()
        let stageChanged = currentProgress?.stage != progress.stage
        guard stageChanged || now.timeIntervalSince(lastProgressPublishedAt) >= 0.5 else { return }
        if stageChanged {
            let previousElapsed = Int(now.timeIntervalSince(stageStartedAt))
            Log.app.notice(
                "Queue stage \(progress.stage.rawValue, privacy: .public) for \(itemID, privacy: .public), provider=\(progress.provider.rawValue, privacy: .public), audio=\(Int(progress.totalSeconds))s, previousStage=\(self.currentProgress?.stage.rawValue ?? "none", privacy: .public) took \(previousElapsed)s"
            )
            stageStartedAt = now
        }
        lastProgressPublishedAt = now
        currentProgress = progress
    }

    private func stopProgressTicks() {
        progressTickTask?.cancel()
        progressTickTask = nil
    }

    private func loadAudioData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }

    private func makeQueueItem(
        id: UUID,
        action: QueueAction,
        providerOverride: TranscriptionProvider?,
        whisperModelOverride: String?,
        targetLanguage: String?,
        localFallbackOnUsageLimit: Bool
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
            targetLanguage: targetLanguage,
            localFallbackOnUsageLimit: localFallbackOnUsageLimit
        )
    }

    private func configuredProvider(for item: QueueItem) -> TranscriptionProvider {
        if item.action == .transcribe,
           storage.recordings
           .first(where: { $0.id == item.id })?
           .requiresLocalTranscription == true
        {
            return .local
        }
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
        guard hasCloudCredentials else { return String(localized: "Sign in to use Diduny transcription.") }
        switch provider {
        case .cloud:
            return nil
        case .local:
            if item.action == .translate {
                let targetLanguage = item.targetLanguage
                    ?? SettingsStorage.shared.defaultTranslationLanguagePair.languageB
                if targetLanguage != "en",
                   item.targetLanguage != nil || !SettingsStorage.shared.defaultTranslationLanguagePair.contains("en")
                {
                    return String(
                        localized: "Local Whisper can translate to English only. Switch Translation Provider to Cloud or choose English."
                    )
                }
            }
            let modelName = item.whisperModelOverride ?? SettingsStorage.shared.selectedWhisperModel
            guard localModelIsAvailable(modelName) else {
                return String(localized: "Download a local Whisper model in Settings.")
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
        return hasSession()
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
        for recording in storage.recordings where recording.status == .processing {
            storage.updateRecording(id: recording.id, status: .unprocessed, error: nil)
        }
    }
}
