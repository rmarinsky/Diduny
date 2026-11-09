import Foundation
import os

/// A realtime service as one session: its own instance, its own coalescer. Nothing it reports passes the
/// controller's id check once it is no longer current.
@MainActor
final class RealtimeEngineSession: MeetingEngineSession {
    private let service: RealtimeTranscriptionProtocol
    private let connect: (RealtimeTranscriptionProtocol) async throws -> Void
    private let coalescer: RealtimeTokenCoalescer?
    nonisolated let audioConsumer: @Sendable (Data) -> Void

    /// `preprocess` runs on the socket's thread, in order. `coalesce` batches to ≤10 Hz for the @Observable stores.
    init(
        service: RealtimeTranscriptionProtocol,
        coalesce: Bool = true,
        preprocess: (([RealtimeToken]) -> [RealtimeToken])? = nil,
        callbacks: MeetingSessionCallbacks,
        connect: @escaping (RealtimeTranscriptionProtocol) async throws -> Void
    ) {
        self.service = service
        self.connect = connect
        audioConsumer = { [weak service] data in service?.sendAudioData(data) }
        let onTokens = callbacks.tokens
        let coalescer = coalesce ? RealtimeTokenCoalescer(onFlush: onTokens) : nil
        self.coalescer = coalescer
        service.onTokensReceived = { tokens in
            let tokens = preprocess?(tokens) ?? tokens
            if let coalescer {
                coalescer.add(tokens)
            } else if !tokens.isEmpty {
                Task { @MainActor in onTokens([.tokens(tokens)]) }
            }
        }
        // Through the coalescer, so boundaries stay ordered relative to the batches it holds.
        service.onSegmentBoundary = { boundary in
            if let coalescer {
                coalescer.addBoundary(boundary)
            } else {
                Task { @MainActor in onTokens([.segmentBoundary(boundary)]) }
            }
        }
        let onStatus = callbacks.status, onError = callbacks.error
        service.setConnectionHandlers(
            onError: { error in
                Log.transcription.error("Realtime transcription error: \(error.localizedDescription)")
                Task { @MainActor in onError(error) } // The file recording continues independently.
            },
            onConnectionStatusChanged: { status in Task { @MainActor in onStatus(status) } }
        )
    }

    func start() async throws {
        try await connect(service)
    }

    func finish(cap: Duration?) async -> Bool {
        let service = service
        let confirmed: Bool
        if let cap {
            confirmed = await firstResult(cap: cap) { await service.finalize(profile: .safe).didReceiveFinishedSignal }
        } else {
            confirmed = await service.finalize(profile: .safe).didReceiveFinishedSignal
        }
        await service.disconnect()
        await coalescer?.flushNow()
        service.clearCallbacks()
        return confirmed
    }

    func cancel() async {
        await service.disconnect()
        service.clearCallbacks()
    }
}

/// Whisper's live preview. Audio stays on this Mac. Its text is provisional until the cut commits it (C6).
@MainActor
final class WhisperEngineSession: MeetingEngineSession {
    private let whisper: WhisperTranscriptionService
    let stream: LocalWhisperStreamingService
    /// This session's own hold, so an old session's tail cannot release the next one's.
    private let holdID = UUID()
    nonisolated let audioConsumer: @Sendable (Data) -> Void

    init(whisper: WhisperTranscriptionService, callbacks: MeetingSessionCallbacks) {
        self.whisper = whisper
        let onTokens = callbacks.tokens, onStatus = callbacks.status
        let stream = LocalWhisperStreamingService(
            transcribe: { samples in try await whisper.transcribeRawSamples(samples) },
            onText: { text in await onTokens([.tokens([RealtimeToken(text: text, isFinal: false)])]) },
            onError: { error in
                Log.whisper.warning("Local meeting preview failed: \(error.localizedDescription)")
                await onStatus(.failed("Live preview unavailable"))
            }
        )
        self.stream = stream
        audioConsumer = { data in Task { await stream.appendPCM16(data) } }
    }

    func start() async throws {
        try await whisper.prepareForStreaming(holdID)
    }

    func finish(cap: Duration?) async -> Bool {
        let stream = stream
        if let cap {
            _ = await firstResult(cap: cap) { await stream.stop(); return true }
        } else {
            await stream.stop()
        }
        whisper.endStreamingHold(holdID)
        return true
    }

    func cancel() async {
        await stream.stop()
        whisper.endStreamingHold(holdID)
    }
}

/// Readiness for a mid-meeting choice: unlike the menus' source, it really checks Whisper's model and the Diduny session.
@MainActor
struct MeetingEngineReadiness: EngineReadinessSource {
    var base: any EngineReadinessSource
    var hasWhisperModel: () -> Bool
    var signedIn: () -> Bool
    var hasQuota: () -> Bool

    static func live(checksQuota: Bool = true) -> MeetingEngineReadiness {
        MeetingEngineReadiness(
            base: LiveEngineReadinessSource(),
            hasWhisperModel: {
                #if TEST_BUILD
                    if UITestHarness.value(of: "--ui-testing-whisper-models") != nil { return true }
                #endif
                return WhisperModelManager.shared.selectedModel() != nil
            },
            signedIn: { AuthService.hasStoredSession },
            hasQuota: {
                !checksQuota || UsageService.canOfferCloudTranscription(
                    hasStoredSession: AuthService.hasStoredSession, usage: UsageService.shared.cachedUsage)
            }
        )
    }

    func readiness(of engine: EngineID) -> EngineReadiness {
        switch engine {
        case .whisper where !hasWhisperModel(): .notDownloaded(bytes: 0)
        case .didunyCloud where !signedIn(): .signedOut
        case .didunyCloud where !hasQuota(): .noQuota
        default: base.readiness(of: engine)
        }
    }
}

/// `work`'s result, or false once `cap` passes. `work` keeps running; the caller disconnects it.
private func firstResult(cap: Duration, _ work: @escaping @Sendable () async -> Bool) async -> Bool {
    await withCheckedContinuation { continuation in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let finish: @Sendable (Bool) -> Void = { value in
            let first = resumed.withLock { done in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
        Task { finish(await work()) }
        Task {
            try? await Task.sleep(for: cap)
            finish(false)
        }
    }
}

// MARK: - Factories

extension AppDelegate {
    /// `translation`: the pair of a Translate meeting's live pipeline; a live session then translates both ways.
    func makeMeetingEngineController(
        start: MeetingEngineTarget, afterStop: EngineID, store: LiveTranscriptStore, sessionID: UUID?,
        translation: TranslationLanguagePair?
    ) -> MeetingEngineController {
        let translating = translation != nil || activeMeetingTranslateTarget != nil
        let overlay = DictationOverlayController.shared
        return MeetingEngineController(start: start, afterStopEngine: afterStop, environment: .init(
            readFrame: { [weak self] in self?.meetingRecorderService.writtenFrames ?? 0 },
            elapsed: { [weak self] in
                guard let self else { return 0 }
                let started = appState.meetingRecordingStartTime ?? appState.meetingTranslationRecordingStartTime
                return started.map { Date().timeIntervalSince($0) } ?? 0
            },
            turns: { overlay.store.meetingTurnCount },
            finalText: { [weak store] in store?.finalTranscriptText ?? "" },
            readiness: { target in
                MeetingEngineController.failure(from: MeetingEngineReadiness.live().readiness(of: target.engine), engine: target.engine)
            },
            makeSession: { [weak self] target, callbacks in
                guard let self else { return nil }
                let pair = translating ? (meetingEngineController?.pendingPair ?? activeMeetingTranslationLanguagePair ?? SettingsStorage.shared.resolveTranslationLanguagePair()) : nil
                let preprocess: (([RealtimeToken]) -> [RealtimeToken])? = translating
                    ? { [weak self] tokens in self?.meetingTranslationTimestampBackfill.annotate(tokens) ?? tokens } : nil
                return makeMeetingEngineSession(target, translationPair: pair, preprocess: preprocess, callbacks: callbacks)
            },
            applyTokens: { [weak self, weak store] events in
                guard let self else { return }
                for event in events {
                    switch event {
                    case let .tokens(tokens):
                        if translating {
                            let translated = filterMeetingTranslatedTokens(tokens)
                            if !translated.isEmpty { store?.processTokens(translated) }
                            updateRecordingFeedbackTokens(tokens, mode: .meetingTranslation)
                        } else {
                            store?.processTokens(tokens)
                            updateRecordingFeedbackTokens(tokens, mode: .meeting)
                        }
                    case .segmentBoundary:
                        if translating { meetingTranslationTimestampBackfill.reset() }
                        store?.markSegmentBoundary()
                        if !translating { markRecordingFeedbackSegmentBoundary(mode: .meeting) }
                    }
                }
            },
            applyStatus: { [weak self, weak store] status in
                guard let self else { return }
                if translating {
                    applyMeetingTranslationConnectionStatus(status, store: store)
                } else {
                    applyMeetingRealtimeConnectionStatus(status, sessionID: sessionID, store: store)
                }
            },
            applyError: { [weak self] error in
                self?.recordMeetingByokError(error, sessionID: sessionID)
                self?.fallBackMeetingToLocalIfUsageUnavailable(error, sessionID: sessionID)
            },
            closeTurn: { [weak store] in
                store?.commitProvisional()
                store?.markSegmentBoundary()
                overlay.store.commitProvisional()
                overlay.store.markSegmentBoundary()
            },
            didCut: { [weak self] target in self?.meetingDidCut(to: target) },
            commitPair: { [weak self] pair in
                self?.commitMeetingTranslationPair(pair)
                overlay.store.meetingTranslationPair = pair
            },
            didChange: { machine in overlay.store.applyMeetingSwitch(machine) }
        ))
    }

    /// The target that now receives audio is the meeting's route from here on.
    private func meetingDidCut(to target: MeetingEngineTarget) {
        activeMeetingTranscriptionProvider = target.isLive ? (target.segment == .cloud ? .cloud : .local) : .local
        guard activeMeetingStartRoute != nil else { return }
        activeMeetingStartRoute = RunTimeRouting.meetingStart(
            segment: target.segment,
            route: RunTimeRoute(engine: target.engine, modelID: nil, unavailable: nil, baseProvider: activeMeetingTranscriptionProvider ?? .local)
        )
    }

    func meetingSwitchHandler(for controller: MeetingEngineController) -> MeetingSwitchHandler {
        MeetingSwitchHandler(
            click: { [weak controller] in controller?.click($0) },
            changePair: { [weak self, weak controller] pair in
                guard let self, let controller else { return false }
                guard controller.machine.running.isLive else {
                    commitMeetingTranslationPair(pair)
                    return true
                }
                controller.restartLive(pair: pair)
                return false // Shown once the cut commits it.
            }
        )
    }

    private func commitMeetingTranslationPair(_ pair: TranslationLanguagePair) {
        activeMeetingTranslationLanguagePair = pair
        activeMeetingTranslationTargetLanguage = pair.languageB
        if activeMeetingTranslateTarget != nil { activeMeetingTranslateTarget = pair.languageB }
    }

    /// ADR-0012 D3 at Stop time: Parakeet still missing gets its stand-in, even when picked in the panel.
    func resolveAfterStopEngine(_ engine: EngineID) -> EffectiveEngineResolver.Result {
        let whisper = WhisperModelManager.shared
        return EffectiveEngineResolver.resolve(
            job: .meeting, segment: .recordOnly,
            override: JobProviderSelection(providerID: engine.rawValue, modelID: nil),
            allowsStandIn: true,
            defaults: SettingsStorage.shared.modeDefaults,
            // Out of quota still resolves: the queue's 402 falls back to Whisper (D5).
            readiness: MeetingEngineReadiness.live(checksQuota: false),
            whisper: .init(downloaded: whisper.downloadedModels, selected: whisper.selectedModel()?.name)
        )
    }

    /// The queue refused the recording at the hand-off and wrote the reason on the row.
    func recordingFailedAtHandOff(_ id: UUID) -> Bool {
        RecordingsLibraryStorage.shared.recordings.first { $0.id == id }?.status == .failed
    }

    /// The Translate meeting that ran on `meetingRecordingState`. One non-live span: today's whole translation.
    /// After a switch: only the part after it (D4).
    func enqueueTranslateMeetingAfterStop(
        _ id: UUID, target: String, history: MeetingEngineHistory?, liveTexts: [Int: String], afterStopEngine: EngineID,
        queue: RecordingQueueService = .shared, resolve: ((EngineID) -> EffectiveEngineResolver.Result)? = nil
    ) -> Bool {
        let stats = meetingRecorderService.lastRecordingStats
        let parts = history.map {
            TranslatePlan.plan(history: $0, liveTexts: liveTexts, afterStopEngine: afterStopEngine,
                               totalFrames: stats.totalFrames, sampleRate: 16000, skippedChunks: stats.skippedChunks)
        } ?? []
        guard (history?.spans.count ?? 1) > 1 || parts.contains(where: { if case .live = $0 { true } else { false } }), !parts.isEmpty else {
            if (history?.spans.count ?? 1) > 1 { Log.app.notice("Translate meeting: offsets unusable, translating the whole recording") }
            // The engine picked last, not the one the meeting started on; never a cloud engine over audio
            // captured under a local one (WP-64 review).
            let used = (history?.spans.map(\.target.engine) ?? []) + [afterStopEngine]
            let wholeEngine = DictationSwitchPlan.wholeFallbackEngine(used: used, preferred: afterStopEngine)
            if wholeEngine != afterStopEngine { Log.app.notice("Translate meeting: whole-recording fallback kept on this Mac") }
            switch resolve?(wholeEngine) ?? resolveAfterStopEngine(wholeEngine) {
            case let .engine(engine, _), let .fallback(engine, _, _):
                return queue.enqueue([id], action: .translate, targetLanguage: target, engineOverride: engine)
            case .none:
                return false // Unprocessed, with the save-only line.
            }
        }
        return queue.enqueue([id], action: .translateParts(standInParts(parts), target: target))
    }

    /// The parts for a live Translate meeting after a switch; nil when the one-span path applies. Empty: offsets
    /// are unusable, translate the whole recording.
    func translateMeetingParts(history: MeetingEngineHistory?, liveTexts: [Int: String], afterStopEngine: EngineID) -> [TranslatePart]? {
        guard let history, history.spans.count > 1 || history.spans.first?.failedAtFrame != nil else { return nil }
        let stats = meetingRecorderService.lastRecordingStats
        return standInParts(TranslatePlan.plan(history: history, liveTexts: liveTexts, afterStopEngine: afterStopEngine,
                                               totalFrames: stats.totalFrames, sampleRate: 16000, skippedChunks: stats.skippedChunks))
    }

    /// Each after-Stop part gets the engine that can run at Stop: a missing Parakeet gets its stand-in.
    private func standInParts(_ parts: [TranslatePart]) -> [TranslatePart] {
        parts.map { part in
            guard case let .afterStop(range, engine) = part else { return part }
            switch resolveAfterStopEngine(engine) {
            case let .engine(id, _), let .fallback(id, _, _): return .afterStop(range: range, engine: id)
            case .none: return part
            }
        }
    }

    func applyMeetingTranslationConnectionStatus(_ status: RealtimeConnectionStatus, store: LiveTranscriptStore?) {
        store?.connectionStatus = status
        updateRecordingFeedbackConnectionStatus(status, mode: .meetingTranslation)
        if let id = meetingRecorderService.currentRecordingId {
            let detail: String? = switch status {
            case .connecting, .reconnecting: "Reconnecting…"
            case let .failed(message):
                message.isEmpty
                    ? "Live transcript interrupted — audio still recording"
                    : "Live transcript interrupted — audio still recording (\(message))"
            case .connected, .disconnected: nil
            }
            RecordingsLibraryStorage.shared.updateStatusDetail(id: id, detail: detail)
        }
    }

    /// A new session for `target`, never reading `activeMeetingStartRoute`. Fresh instances (C4).
    func makeMeetingEngineSession(
        _ target: MeetingEngineTarget,
        translationPair: TranslationLanguagePair?,
        preprocess: (([RealtimeToken]) -> [RealtimeToken])?,
        callbacks: MeetingSessionCallbacks
    ) -> MeetingEngineSession? {
        guard case let .live(engine) = target else { return nil }
        switch engine {
        case .whisper:
            let session = WhisperEngineSession(whisper: whisperTranscriptionService, callbacks: callbacks)
            localMeetingStreamingService = session.stream
            return session
        case .appleSpeech:
            guard let apple = makeAppleMeetingService(forceReady: true) else { return nil }
            return realtimeSession(apple, translationPair: nil, preprocess: nil, callbacks: callbacks)
        case .elevenLabs:
            guard let service = makeElevenLabsMeetingService(selection: JobProviderSelection(providerID: engine.rawValue, modelID: nil))
            else { return nil }
            return realtimeSession(service, translationPair: nil, preprocess: nil, callbacks: callbacks)
        case .didunyCloud:
            return realtimeSession(CloudRealtimeService(), translationPair: translationPair, preprocess: preprocess, callbacks: callbacks)
        case .parakeet:
            return nil // Never live.
        }
    }

    private func realtimeSession(
        _ service: RealtimeTranscriptionProtocol,
        translationPair: TranslationLanguagePair?,
        preprocess: (([RealtimeToken]) -> [RealtimeToken])?,
        callbacks: MeetingSessionCallbacks
    ) -> RealtimeEngineSession {
        RealtimeEngineSession(service: service, coalesce: translationPair == nil, preprocess: preprocess, callbacks: callbacks) { service in
            if let translationPair {
                let hints = SettingsStorage.shared.translationLanguageHints(for: translationPair)
                try await service.connect(
                    languageHints: hints, strictLanguageHints: !hints.isEmpty, audioConfig: .defaultPCM16kMono,
                    translationConfig: RealtimeTranslationConfig(
                        mode: .twoWay(languageA: translationPair.languageA, languageB: translationPair.languageB)
                    )
                )
            } else {
                let hints = SettingsStorage.shared.speechLanguageHints
                try await service.connect(languageHints: hints, strictLanguageHints: !hints.isEmpty)
            }
        }
    }
}
