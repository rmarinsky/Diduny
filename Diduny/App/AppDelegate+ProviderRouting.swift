import AppKit
import Foundation

// MARK: - Provider Routing

extension AppDelegate {
    /// Engine for a job, resolved through ProviderRegistry + JobRouter from the per-job default.
    func routedProvider(for job: STTJob, legacy: TranscriptionProvider) -> TranscriptionProvider {
        ProviderEngineRouting.engine(
            for: job,
            selection: SettingsStorage.shared.providerDefaults.selection(for: job),
            legacy: legacy,
            context: providerRoutingContext
        )
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
            selection: SettingsStorage.shared.providerDefaults.selection(for: .dictation),
            context: providerRoutingContext
        )
    }

    /// The ElevenLabs plan for meetings when the user picked an ElevenLabs model and it is routable, else nil.
    var elevenLabsMeetingPlan: ExecutionPlan? {
        ProviderEngineRouting.byokPlan(
            for: .meeting,
            providerID: STTProviderID.elevenLabs,
            selection: SettingsStorage.shared.providerDefaults.selection(for: .meeting),
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

    /// Whether dictation translation runs on ElevenLabs (then the Diduny text translation step).
    var elevenLabsTranslationDecision: ByokTranslationStep.StartDecision {
        let selection = SettingsStorage.shared.providerDefaults.selection(for: .dictationTranslation)
        let availability = EngineOptions.translationAvailability()
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

    var routedTranslationProvider: TranscriptionProvider {
        routedProvider(
            for: .dictationTranslation,
            legacy: SettingsStorage.shared.effectiveTranslationProvider
        )
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
