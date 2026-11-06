import AppKit
import Foundation

// MARK: - Provider Routing

extension AppDelegate {
    /// What a job runs now, from Settings > Modes (WP-17). `.meeting` reads the running meeting, else "Starts in".
    func modeRoute(for job: STTJob, segment: MeetingSegment? = nil, override: JobProviderSelection? = nil) -> RunTimeRoute {
        if job == .meeting, segment == nil, override == nil, let running = activeMeetingStartRoute {
            return RunTimeRoute(engine: running.engine, modelID: running.modelID, unavailable: nil,
                                baseProvider: running.provider)
        }
        let whisper = WhisperModelManager.shared
        return RunTimeRouting.route(
            job: job,
            segment: segment,
            override: override,
            defaults: SettingsStorage.shared.modeDefaults,
            readiness: LiveEngineReadinessSource(),
            whisper: .init(downloaded: whisper.downloadedModels, selected: whisper.selectedModel()?.name),
            signedIn: AuthService.hasStoredSession
        )
    }

    /// How a meeting starts in `segment` (default "Starts in"); `override` is a pick for this meeting only.
    func meetingStartRoute(segment: MeetingSegment? = nil, override: JobProviderSelection? = nil) -> MeetingStartRoute {
        let segment = segment ?? SettingsStorage.shared.modeDefaults.meetingStartsIn
        return RunTimeRouting.meetingStart(segment: segment, route: modeRoute(for: .meeting, segment: segment, override: override))
    }

    /// The Cloud/Local flow for a job.
    func routedProvider(for job: STTJob) -> TranscriptionProvider {
        modeRoute(for: job).baseProvider
    }

    var providerRoutingContext: RoutingContext {
        RoutingContext(
            providersWithKey: Set(ProviderRegistry.shared.modules.filter {
                $0.requiresKey && ProviderKeyStore.shared.hasKey(for: $0.id)
            }.map(\.id)),
            didunyTranslationAvailable: AuthService.hasStoredSession
        )
    }

    /// The ElevenLabs plan for dictation when the user picked an ElevenLabs model and it is routable, else nil.
    var elevenLabsDictationPlan: ExecutionPlan? {
        ProviderEngineRouting.byokPlan(
            for: .dictation,
            providerID: STTProviderID.elevenLabs,
            selection: modeRoute(for: .dictation).selection,
            context: providerRoutingContext
        )
    }

    /// Parakeet V3 or Apple selected for the job and ready on this Mac; they transcribe the capture after Stop.
    func onDeviceEngine(for job: STTJob) -> (any BenchmarkEngine)? {
        OnDeviceEngines.engine(id: onDeviceSelection(for: job))
    }

    /// Parakeet / Apple id when the job runs one, ready or not. A meeting reads its after-Stop engine.
    func onDeviceSelection(for job: STTJob) -> String? {
        if job == .meeting { return (activeMeetingStartRoute ?? meetingStartRoute()).afterStopEngineID }
        return modeRoute(for: job).onDeviceEngineID
    }

    /// Error to show at Start when the job's on-device engine is selected but not ready; nil when fine.
    func onDeviceEngineStartError(for job: STTJob) -> String? {
        let route = modeRoute(for: job)
        if let error = RunTimeRouting.startError(route.unavailable, engine: route.engine) { return error }
        guard onDeviceSelection(for: job) != nil, onDeviceEngine(for: job) == nil else { return nil }
        return OnDeviceEngines.notReadyMessage
    }

    /// Same check for a meeting about to start in a given segment.
    func onDeviceEngineStartError(for start: MeetingStartRoute) -> String? {
        if let error = RunTimeRouting.startError(start.unavailable, engine: start.engine) { return error }
        guard let id = start.afterStopEngineID, OnDeviceEngines.engine(id: id) == nil else { return nil }
        return OnDeviceEngines.notReadyMessage
    }

    /// Dictation runs on the user's own engine (ElevenLabs key or an on-device engine): no Diduny server cleanup.
    /// Uses the selection, not readiness, so an on-device choice that stops being ready fails instead of
    /// silently sending audio to a cloud provider.
    var dictationUsesOwnEngine: Bool {
        elevenLabsDictationPlan != nil || onDeviceSelection(for: .dictation) != nil
    }

    /// Transcribes a capture with the engine the user picked for the job. Never falls back to another provider.
    func transcribeWithOwnEngine(job: STTJob, audioData: Data) async throws -> String {
        guard onDeviceSelection(for: job) != nil else {
            let engine = modeRoute(for: job).engine
            if engine == .whisper { return try await whisperTranscriptionService.transcribe(audioData: audioData) }
            guard engine == .elevenLabs else {
                throw TranscriptionError.apiError(String(localized: "The selected engine isn't available. Check Settings › Providers."))
            }
            return try await transcribeWithElevenLabsBatch(audioData: audioData)
        }
        guard let engine = onDeviceEngine(for: job) else {
            throw TranscriptionError.apiError(String(localized: "The selected on-device engine isn't ready on this Mac. Your recording is saved."))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diduny-local-\(UUID().uuidString).wav")
        try audioData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let language = SettingsStorage.shared.speechLanguageHints.first ?? BenchmarkRunner.defaultLanguage
        let text = try await engine.transcribe(url, language: language).text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionError.emptyTranscription }
        return text
    }

    /// The ElevenLabs plan for meetings when the user picked an ElevenLabs model and it is routable, else nil.
    var elevenLabsMeetingPlan: ExecutionPlan? {
        ProviderEngineRouting.byokPlan(
            for: .meeting,
            providerID: STTProviderID.elevenLabs,
            selection: (activeMeetingStartRoute ?? meetingStartRoute()).selection,
            context: providerRoutingContext
        )
    }

    /// Live ElevenLabs session for a meeting: VAD commits plus a manual commit every ~25 s, reconnecting on
    /// session limit or drop (bounded) so multi-hour meetings keep their committed text. Nil when not selected.
    func makeElevenLabsMeetingService() -> ElevenLabsRealtimeService? {
        guard elevenLabsMeetingPlan?.mode == .live,
              let key = ProviderKeyStore.shared.key(for: STTProviderID.elevenLabs) else { return nil }
        return ElevenLabsRealtimeService(
            apiKey: key,
            commitStrategy: .vad,
            maxReconnects: 50,
            periodicCommitInterval: 25,
            reconnectOnDrop: true
        )
    }

    /// Live Apple session for a meeting when Apple is the meeting engine and ready; nil otherwise.
    func makeAppleMeetingService() -> AppleLiveTranscriptionService? {
        let start = activeMeetingStartRoute ?? meetingStartRoute()
        guard start.segment != .recordOnly, start.engine == .appleSpeech,
              OnDeviceEngines.engine(id: STTProviderID.appleSpeech) != nil else { return nil }
        return AppleLiveTranscriptionService(farField: true)
    }

    /// After Stop: names the ElevenLabs failure and offers a one-off Diduny Cloud transcription of the saved audio.
    func presentMeetingByokError(_ error: ElevenLabsError, recordingID: UUID?) {
        let availability = EngineOptions.translationAvailability()
        let alert = NSAlert()
        alert.messageText = error.errorDescription ?? ""
        alert.informativeText = String(localized: "Your recording is saved.") + " " + (
            !availability.signedIn ? String(localized: "Sign in to use Diduny Cloud")
                : !availability.available ? String(localized: "Diduny quota used up")
                : String(localized: "Uses your Diduny quota for this recording only. Your defaults don't change.")
        )
        alert.addButton(withTitle: String(localized: "OK"))
        let cloudButton = alert.addButton(withTitle: String(localized: "Use Diduny Cloud for this recording"))
        cloudButton.isEnabled = availability.available && recordingID != nil
        guard alert.runModal() == .alertSecondButtonReturn, let recordingID else { return }
        RecordingQueueService.shared.enqueue([recordingID], action: .transcribeDiarize, providerOverride: .cloud)
    }

    /// Whether dictation translation into `target` runs on the user's own engine, then the Diduny text step.
    /// Whisper translates itself only where its model can (bug 9); otherwise it transcribes and Diduny translates.
    func translationStartDecision(target: String) -> ByokTranslationStep.StartDecision {
        let route = modeRoute(for: .dictationTranslation)
        let availability = EngineOptions.translationAvailability()
        let whisperStep = route.engine == .whisper && !JobRequest.whisperTranslationUsable(
            model: WhisperModelManager.shared.selectedModel()?.name, target: target)
        if route.onDeviceEngineID != nil || whisperStep {
            return availability.available
                ? .run(ExecutionPlan(mode: .afterStop, translation: .didunyStep))
                : .translationUnavailable(signedIn: availability.signedIn)
        }
        let selection = route.selection
        var context = providerRoutingContext
        context.didunyTranslationAvailable = availability.available
        return ByokTranslationStep.startDecision(
            providerID: STTProviderID.elevenLabs,
            selection: selection,
            plan: ProviderEngineRouting.byokPlan(
                for: .dictationTranslation,
                providerID: STTProviderID.elevenLabs,
                selection: selection,
                context: context
            ),
            context: context,
            signedIn: availability.signedIn
        )
    }

    /// Local Whisper translation (Whisper alone, or Diduny Cloud signed out): Whisper translates only where its
    /// model can (bug 9); otherwise the transcript is returned untranslated.
    func localWhisperTranslation(audioData: Data, targetLanguage: String) async throws -> String {
        guard JobRequest.whisperTranslationUsable(model: WhisperModelManager.shared.selectedModel()?.name, target: targetLanguage)
        else { return try await whisperTranscriptionService.transcribe(audioData: audioData) }
        return try await whisperTranscriptionService.translateAndTranscribe(audioData: audioData, targetLanguage: targetLanguage)
    }

    var routedTranslationProvider: TranscriptionProvider {
        routedProvider(for: .dictationTranslation)
    }

    /// Transcribes a WAV capture with ElevenLabs batch and queues the provider-side copy for deletion.
    func transcribeWithElevenLabsBatch(audioData: Data) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diduny-el-\(UUID().uuidString).wav")
        try audioData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let hints = SettingsStorage.shared.speechLanguageHints
        let result = try await ElevenLabsBatchService().transcribe(
            audioURL: url,
            languageCode: hints.count == 1 ? hints[0] : nil
        )
        if let id = result.transcriptionID {
            Task {
                await RemoteDeletionQueue.shared.enqueue(providerID: STTProviderID.elevenLabs, remoteID: id)
                await RemoteDeletionQueue.shared.process()
            }
        }
        return result.transcript.text
    }

    /// Drains pending provider-side deletes at launch and every 5 minutes.
    func startRemoteDeletionQueue() {
        Task { await RemoteDeletionQueue.shared.process() }
        remoteDeletionTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { await RemoteDeletionQueue.shared.process() }
        }
    }
}

extension RemoteDeletionQueue {
    static let shared = RemoteDeletionQueue(
        fileURL: defaultFileURL,
        deleters: [STTProviderID.elevenLabs: ElevenLabsTranscriptDeleter()],
        apiKey: { ProviderKeyStore.shared.key(for: $0) },
        onAuthFailure: { _ in
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn't delete a transcript from ElevenLabs")
                alert.informativeText = String(
                    localized: "Your ElevenLabs key isn't allowed to delete transcripts. Delete them in your ElevenLabs account, or save a key with speech-to-text delete access."
                )
                alert.runModal()
            }
        }
    )
}
