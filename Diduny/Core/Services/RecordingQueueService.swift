import Foundation

@Observable
@MainActor
final class RecordingQueueService {
    static let shared = RecordingQueueService()

    enum QueueAction: Equatable {
        case transcribe
        case transcribeDiarize
        case translate
        /// Translate meeting after a switch (ADR-0013 D4): kept live text and translated ranges, in time order.
        case translateParts([TranslatePart], target: String)
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
        /// The engine the meeting ran (Record only, Translate meeting); nil reads Settings › Modes.
        var engineOverride: EngineID? = nil
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
    /// Tests replace the engines.
    private let makeRunner: (@MainActor (URL) -> QueueEngineRunner)?

    init(
        storage: RecordingsLibraryStorage? = nil,
        startsAutomatically: Bool = true,
        localModelIsAvailable: ((String) -> Bool)? = nil,
        hasSession: @escaping () -> Bool = { AuthService.hasStoredSession },
        makeRunner: (@MainActor (URL) -> QueueEngineRunner)? = nil
    ) {
        self.storage = storage ?? .shared
        self.startsAutomatically = startsAutomatically
        self.hasSession = hasSession
        self.makeRunner = makeRunner
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
        localFallbackOnUsageLimit: Bool = false,
        engineOverride: EngineID? = nil
    ) -> Bool {
        guard !ids.isEmpty else { return false }

        let newItems = ids.compactMap { id in
            makeQueueItem(
                id: id,
                action: action,
                providerOverride: providerOverride,
                whisperModelOverride: whisperModelOverride,
                targetLanguage: targetLanguage,
                localFallbackOnUsageLimit: localFallbackOnUsageLimit,
                engineOverride: engineOverride
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

        if case let .translateParts(parts, target) = item.action {
            await processTranslateParts(parts, target: target, item: item, recording: recording, audioURL: originalAudioURL)
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

            let onDeviceID = item.action == .translate
                ? onDeviceTranslationEngineID(for: item, recording: recording)
                : onDeviceEngineID(for: item, recording: recording)
            let onDevice = OnDeviceEngines.engine(id: onDeviceID)
            if onDeviceID != nil, onDevice == nil {
                storage.updateRecording(id: item.id, status: .failed, error: OnDeviceEngines.notReadyMessage)
                return
            }
            if onDevice == nil, let error = preflightError(for: item, provider: provider) {
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

            let runner = makeRunner?(audioURL)
                ?? makeEngineRunner(service: service, audioURL: audioURL, recording: recording, itemID: item.id)
            let whisperModel = item.whisperModelOverride ?? SettingsStorage.shared.selectedWhisperModel
            var transcript: GeneratedTranscript
            let status: Recording.ProcessingStatus
            let translationTargetLanguageCode: String?
            let historyKind: TranscriptVersion.Kind
            let sourceLanguageCode: String?
            switch item.action {
            case .transcribe:
                if let engine = item.engineOverride {
                    transcript = try await runner.transcribe(engine, diarize: false, hints: SettingsStorage.shared.speechLanguageHints)
                } else if let onDevice {
                    let language = SettingsStorage.shared.speechLanguageHints.first ?? BenchmarkRunner.defaultLanguage
                    transcript = try await GeneratedTranscript(text: onDevice.transcribe(audioURL, language: language).text)
                } else if provider == .cloud {
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
                historyKind = provider == .local || onDevice != nil ? .local : .cloud
                sourceLanguageCode = nil
            case .transcribeDiarize:
                // C10: a named engine runs itself; ElevenLabs must not go to Diduny jobs.
                if let engine = item.engineOverride {
                    transcript = try await runner.transcribe(engine, diarize: true, hints: SettingsStorage.shared.speechLanguageHints)
                } else if let onDevice {
                    let language = SettingsStorage.shared.speechLanguageHints.first ?? BenchmarkRunner.defaultLanguage
                    transcript = try await GeneratedTranscript(text: onDevice.transcribe(audioURL, language: language).text)
                } else if provider == .cloud {
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
                historyKind = provider == .local || onDevice != nil ? .local : .cloud
                sourceLanguageCode = nil
            case .translate:
                let pair = SettingsStorage.shared.resolveTranslationLanguagePair()
                let targetLanguage: String
                if let engine = item.engineOverride {
                    targetLanguage = item.targetLanguage ?? pair.languageB
                    transcript = try await runner.translate(engine, target: targetLanguage, whisperModel: whisperModel)
                } else if let onDevice {
                    // Transcribe on this Mac, then translate the final text once with Diduny (text only).
                    targetLanguage = item.targetLanguage ?? pair.languageB
                    let original = try await onDevice.transcribe(audioURL, language: pair.languageA).text
                    let step = await ByokTranslationStep.translate(original, targetLanguage: targetLanguage, translator: DidunyTextTranslationService())
                    guard step.translated else {
                        throw TranscriptionError.apiError(String(localized: "Translation failed. Try again from the recording."))
                    }
                    transcript = GeneratedTranscript(text: step.text)
                } else if provider == .cloud {
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
                    // Whisper translates itself only into English on a model that can; else Diduny
                    // translates its text into the target (bug 3). Never rewritten to English.
                    targetLanguage = item.targetLanguage ?? pair.languageB
                    transcript = try await runner.translate(.whisper, target: targetLanguage, whisperModel: whisperModel)
                }
                status = .translated
                translationTargetLanguageCode = targetLanguage
                historyKind = .translation
                sourceLanguageCode = pair.languageA
            case .translateParts:
                return // Handled above.
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
                targetLanguage: item.targetLanguage,
                // A named engine stays named, so the retry is Whisper through the same runner.
                engineOverride: item.engineOverride == nil ? nil : .whisper
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

    /// Translates only the ranges without live text and joins them with the kept live text. A failed range keeps
    /// what is ready, with `.failed` and the error; the audio stays, so a whole translation can still run.
    private func processTranslateParts(
        _ parts: [TranslatePart], target: String, item: QueueItem, recording: Recording, audioURL: URL
    ) async {
        let whisperModel = item.whisperModelOverride ?? SettingsStorage.shared.selectedWhisperModel
        let result = await QueueEngineRunner.translateParts(parts) { [self] range, engine in
            let partURL = try await AudioTrimService.prepareAudio(fileURL: audioURL, range: range)
            defer { if partURL != audioURL { try? FileManager.default.removeItem(at: partURL) } }
            let runner = makeRunner?(partURL) ?? makeEngineRunner(
                service: createTranscriptionService(
                    for: engine == .didunyCloud || engine == .elevenLabs ? .cloud : .local,
                    whisperModelOverride: item.whisperModelOverride
                ),
                audioURL: partURL, recording: recording, itemID: item.id
            )
            return try await runner.translate(engine, target: target, whisperModel: whisperModel).text
        }
        if result.error is CancellationError {
            storage.updateRecording(id: item.id, status: .unprocessed, error: nil)
        } else if let error = result.error {
            storage.updateRecording(id: item.id, status: .failed, text: result.text.isEmpty ? nil : result.text,
                                    error: error.localizedDescription)
            Log.app.error("Queue failed a translate part for recording \(item.id): \(error.localizedDescription)")
        } else {
            storage.completeTranscription(
                id: item.id, status: .translated,
                text: ClipboardService.preparedMessageText(result.text, recordingType: recording.type), segments: nil,
                translationTargetLanguageCode: target, kind: .translation, provider: TranscriptionProvider.cloud.rawValue
            )
        }
    }

    /// The engines for one item; Whisper reports progress through `service`.
    private func makeEngineRunner(
        service: TranscriptionServiceProtocol, audioURL: URL, recording: Recording, itemID: UUID
    ) -> QueueEngineRunner {
        QueueEngineRunner(
            cloud: { [unowned self] config in
                try await transcribeViaJobs(audioFileURL: audioURL, config: config, source: recording.audioFileName,
                                            sourceDurationSeconds: recording.effectiveDurationSeconds, itemID: itemID)
            },
            whisper: { [unowned self] in try await service.transcribeDetailed(audioData: loadAudioData(from: audioURL)) },
            whisperTranslateToEnglish: { [unowned self] in
                try await service.translateAndTranscribe(audioData: loadAudioData(from: audioURL), targetLanguage: "en")
            },
            onDevice: { id in
                guard let engine = OnDeviceEngines.engine(id: id) else {
                    throw TranscriptionError.apiError(OnDeviceEngines.notReadyMessage)
                }
                let language = SettingsStorage.shared.speechLanguageHints.first ?? BenchmarkRunner.defaultLanguage
                return try await engine.transcribe(audioURL, language: language).text
            },
            elevenLabs: { diarize in try await Self.transcribeWithElevenLabs(audioURL: audioURL, diarize: diarize) },
            translator: DidunyTextTranslationService()
        )
    }

    /// ElevenLabs Scribe v2 batch with the user's key; the provider-side copy is queued for deletion.
    private static func transcribeWithElevenLabs(audioURL: URL, diarize: Bool) async throws -> GeneratedTranscript {
        let hints = SettingsStorage.shared.speechLanguageHints
        let result = try await ElevenLabsBatchService().transcribe(
            audioURL: audioURL, languageCode: hints.count == 1 ? hints[0] : nil, diarize: diarize)
        if let id = result.transcriptionID {
            Task {
                await RemoteDeletionQueue.shared.enqueue(providerID: STTProviderID.elevenLabs, remoteID: id)
                await RemoteDeletionQueue.shared.process()
            }
        }
        return result.transcript
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
        Self.buildCloudTranscriptionConfig(
            hints: SettingsStorage.shared.speechLanguageHints,
            enableSpeakerDiarization: enableSpeakerDiarization
        )
    }

    /// Empty hints (no "Languages you speak") send no hint and no strict flag: the engine detects (T5-LA-23).
    static func buildCloudTranscriptionConfig(hints: [String], enableSpeakerDiarization: Bool) -> [String: Any] {
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

    /// The transcript of one recording for the command panel outcome; another recording's
    /// progress never shows (WP-42).
    func transcriptState(for id: UUID?) -> OutcomeTranscriptState {
        OutcomeTranscriptState.make(
            recordingID: id,
            isQueued: id.map(isQueued) ?? false,
            currentRecordingID: currentRecordingId,
            currentProgress: currentProgress
        )
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
        localFallbackOnUsageLimit: Bool,
        engineOverride: EngineID?
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
            localFallbackOnUsageLimit: localFallbackOnUsageLimit,
            engineOverride: engineOverride
        )
    }

    /// Parakeet / Apple chosen for this recording's mode. An explicit Diduny Cloud override and
    /// translations keep their own path.
    private func onDeviceEngineID(for item: QueueItem, recording: Recording) -> String? {
        if let engine = item.engineOverride { return Self.onDeviceID(engine) }
        guard item.providerOverride != .cloud, item.action != .translate else { return nil }
        let job: STTJob = switch recording.type {
        case .meeting: .meeting
        case .meetingTranslation: .meetingTranslation
        case .fileTranscription: .file
        case .translation: .dictationTranslation
        case .voice: .dictation
        }
        let id = SettingsStorage.shared.modeDefaults.engine(for: job).rawValue
        return STTProviderID.onDeviceEngines.contains(id) ? id : nil
    }

    /// Parakeet / Apple chosen for this recording's translation mode (meetings → meeting translation).
    private func onDeviceTranslationEngineID(for item: QueueItem, recording: Recording) -> String? {
        if let engine = item.engineOverride { return Self.onDeviceID(engine) }
        guard item.providerOverride != .cloud else { return nil }
        let job: STTJob = recording.type == .meeting || recording.type == .meetingTranslation ? .meetingTranslation : .dictationTranslation
        let id = SettingsStorage.shared.modeDefaults.engine(for: job).rawValue
        return STTProviderID.onDeviceEngines.contains(id) ? id : nil
    }

    private static func onDeviceID(_ engine: EngineID) -> String? {
        STTProviderID.onDeviceEngines.contains(engine.rawValue) ? engine.rawValue : nil
    }

    private func configuredProvider(for item: QueueItem) -> TranscriptionProvider {
        if let engine = item.engineOverride {
            return engine == .didunyCloud || engine == .elevenLabs ? .cloud : .local
        }
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

        // Inventory F8: no override reads the Dictation (or Translation) engine from Settings > Modes,
        // the mode whose legacy Cloud/Local key this used to read, with the run-time Cloud/Local rule.
        let job: STTJob = item.action == .translate ? .dictationTranslation : .dictation
        return RunTimeRouting.baseProvider(for: SettingsStorage.shared.modeDefaults.engine(for: job),
                                           signedIn: AuthService.hasStoredSession)
    }

    private func preflightError(for item: QueueItem) -> String? {
        if case .translateParts = item.action { return nil } // Each part reports its own failure.
        // Same rule as processRecording: an on-device engine skips the Whisper/cloud checks.
        if let recording = storage.recordings.first(where: { $0.id == item.id }) {
            let onDeviceID = item.action == .translate
                ? onDeviceTranslationEngineID(for: item, recording: recording)
                : onDeviceEngineID(for: item, recording: recording)
            if onDeviceID != nil {
                return OnDeviceEngines.engine(id: onDeviceID) == nil ? OnDeviceEngines.notReadyMessage : nil
            }
        }
        return preflightError(for: item, provider: configuredProvider(for: item))
    }

    private func preflightError(for item: QueueItem, provider: TranscriptionProvider) -> String? {
        if item.engineOverride == .elevenLabs {
            // The user's key transcribes; only the Diduny text step needs sign-in.
            guard ProviderKeyStore.shared.hasKey(for: STTProviderID.elevenLabs) else {
                return String(localized: "The selected engine isn't available. Check Settings › Providers.")
            }
            guard item.action != .translate || hasCloudCredentials else {
                return String(localized: "Translation uses Diduny. Sign in to enable it. Transcription with your own provider still works.")
            }
            return nil
        }
        // C22: an engine named for this run that works on this Mac needs no Diduny session.
        guard hasCloudCredentials || (item.engineOverride != nil && provider == .local) else {
            return String(localized: "Sign in to use Diduny transcription.")
        }
        switch provider {
        case .cloud:
            return nil
        case .local:
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
