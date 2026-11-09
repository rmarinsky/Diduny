import Foundation

/// WP-64: the Engine picker of the dictation and translation panels changes the engine during the recording.
extension AppDelegate {
    /// Call after today's realtime setup and before the recorder starts (it snapshots the audio callback).
    /// `translateInto`: the translation's target; nil for dictation.
    func installDictationEngineSwitch(job: STTJob, translateInto target: String?) {
        dictationEngineSwitch = nil
        guard let startConsumer = audioRecorder.onRealtimeAudioData else { return }
        let route = modeRoute(for: job)
        let startLive = LiveSessionEngine.running(route, job: job)?.hasLiveText ?? true
        let start: MeetingEngineTarget = startLive ? .live(route.engine) : .afterStopOnly(route.engine)
        let feedbackMode: RecordingMode = target == nil ? .voice : .translation(targetLanguage: translationPairLabel)
        let overlay = DictationOverlayController.shared
        let switcher = DictationEngineSwitcher(
            start: start,
            startSession: .init(
                stop: { [weak self] in
                    guard let self else { return .empty }
                    // Today's stop reports a disconnect; the new engine's status must stay (ADR-0013 C5).
                    let service = target == nil
                        ? (dictationRealtimeService ?? realtimeTranscriptionService)
                        : (translationRealtimeService ?? realtimeTranscriptionService)
                    service.setConnectionHandlers(onError: nil, onConnectionStatusChanged: nil)
                    return target == nil
                        ? await stopVoiceRealtimeSession(finalize: true)
                        : await stopTranslationRealtimeSession(finalize: true)
                },
                cancel: { [weak self] in
                    if target == nil {
                        _ = await self?.stopVoiceRealtimeSession(finalize: false)
                    } else {
                        _ = await self?.stopTranslationRealtimeSession(finalize: false)
                    }
                }
            ),
            environment: .init(
                readiness: { target in
                    MeetingEngineController.failure(
                        from: MeetingEngineReadiness.live().readiness(of: target.engine), engine: target.engine)
                },
                makeSession: { [weak self] engineTarget, callbacks in
                    self?.makeDictationEngineSession(engineTarget, translateInto: target, callbacks: callbacks)
                },
                applyTokens: { [weak self] events in
                    for case let .tokens(tokens) in events {
                        self?.updateRecordingFeedbackTokens(tokens, mode: feedbackMode)
                    }
                },
                applyStatus: { [weak self] status in self?.updateRecordingFeedbackConnectionStatus(status, mode: feedbackMode) },
                closeTurn: { overlay.store.commitProvisional() },
                didCut: { [weak self] engineTarget in
                    guard let self else { return }
                    // From the cut on, routing (own engine, cleanup, output switching) follows the new engine.
                    appState.panelEngines[job] = ModeEngineRules.selection(engine: engineTarget.engine, job: job)
                    overlay.store.sessionEngine = LiveSessionEngine.running(modeRoute(for: job), job: job)
                },
                didChange: { machine in overlay.store.meetingSwitch = MeetingSwitchDisplay(machine: machine) }
            )
        )
        audioRecorder.onRealtimeAudioData = switcher.audioCallback(startConsumer: startConsumer)
        dictationEngineSwitch = switcher
    }

    /// The panel's picks reach the switcher only while the recording runs.
    func connectDictationEngineSwitchToPanel(job: STTJob) {
        guard let switcher = dictationEngineSwitch else { return }
        let translating = job == .dictationTranslation
        DictationOverlayController.shared.store.meetingSwitchHandler = MeetingSwitchHandler(
            click: { [weak switcher] picked in
                guard let switcher else { return }
                let engine = picked.engine
                let elevenLabsLive = engine == .elevenLabs
                    && LiveSessionEngine.running(ModeEngineRules.selection(engine: engine, job: job))?.hasLiveText == true
                    && ProviderKeyStore.shared.key(for: STTProviderID.elevenLabs) != nil
                switcher.click(DictationSwitchPlan.target(for: engine, elevenLabsLive: elevenLabsLive, translating: translating))
            },
            changePair: { _ in false }
        )
    }

    /// A new session for a pick, never the shared instances. Diduny Cloud translates live; the others transcribe
    /// and their text is translated after Stop.
    private func makeDictationEngineSession(
        _ target: MeetingEngineTarget, translateInto: String?, callbacks: MeetingSessionCallbacks
    ) -> (session: MeetingEngineSession, sink: DictationSpanSink)? {
        guard case let .live(engine) = target else { return nil }
        let service: RealtimeTranscriptionProtocol
        switch engine {
        case .whisper:
            // A preview on this Mac; the span is transcribed after Stop.
            return (WhisperEngineSession(whisper: whisperTranscriptionService, callbacks: callbacks), DictationSpanSink())
        case .appleSpeech:
            service = AppleLiveTranscriptionService()
        case .elevenLabs:
            guard let key = ProviderKeyStore.shared.key(for: STTProviderID.elevenLabs) else { return nil }
            service = ElevenLabsRealtimeService(apiKey: key)
        case .didunyCloud:
            service = CloudRealtimeService()
        case .parakeet:
            return nil
        }
        let translation = engine == .didunyCloud ? translateInto : nil
        let sink = DictationSpanSink(translatedInto: translation)
        let pair = activeTranslationLanguagePair ?? SettingsStorage.shared.resolveTranslationLanguagePair()
        let hints = translateInto == nil
            ? SettingsStorage.shared.speechLanguageHints
            : SettingsStorage.shared.translationLanguageHints(for: pair)
        let session = RealtimeEngineSession(
            service: service, preprocess: { tokens in sink.add(tokens); return tokens }, callbacks: callbacks
        ) { service in
            try await service.connect(
                languageHints: hints, strictLanguageHints: !hints.isEmpty, audioConfig: .defaultPCM16kMono,
                translationConfig: translation.map { RealtimeTranslationConfig(mode: .oneWay(targetLanguage: $0)) },
                enableSpeakerDiarization: false
            )
        }
        return (session, sink)
    }

    /// Stop, or the panel's Stop: finishes the engines. Before a pick it is today's stop.
    func stopDictationEngines(translating: Bool) async -> RealtimeSessionStopResult {
        if let switcher = dictationEngineSwitch, switcher.isActive {
            await switcher.shutdown(finalize: true)
            if let result = await switcher.startResult() { return result }
        }
        return translating ? await stopTranslationRealtimeSession(finalize: true) : await stopVoiceRealtimeSession(finalize: true)
    }

    /// Cancel: nothing is finished or kept.
    func cancelDictationEngineSwitch() async {
        let switcher = dictationEngineSwitch
        dictationEngineSwitch = nil
        await switcher?.shutdown(finalize: false)
    }

    /// After a switch: the text of every part in order. Live parts keep their text; the others are transcribed
    /// from their own audio by their own engine, and in a translation the text not yet translated is translated
    /// by Diduny. Nil without a switch.
    func dictationSwitchResult(
        audioData: Data, start: RealtimeSessionStopResult, translateInto target: String?
    ) async throws -> RealtimeSessionStopResult? {
        guard let switcher = dictationEngineSwitch, switcher.didSwitch else { return nil }
        let startText = target != nil && switcher.start == .live(.didunyCloud) && translationByokPlan == nil
            ? DictationSwitchPlan.SpanText(text: start.text, translated: true)
            : DictationSwitchPlan.SpanText(text: target == nil ? start.text : start.originalText, translated: false)
        let later = switcher.laterSpanTexts
        var texts: [DictationSwitchPlan.SpanText] = []
        parts: for part in DictationSwitchPlan.parts(switcher.history) {
            switch part {
            case .live(span: 0):
                texts.append(startText)
            case let .live(span):
                texts.append(later[span] ?? .init(text: "", translated: false))
            case let .afterStop(_, engine, from, to):
                if let to, to <= from { continue }
                guard let slice = DictationSwitchPlan.slice(wav: audioData, from: from, to: to) else {
                    // Not a layout the cut can range: the whole recording with the last engine, replacing the text.
                    Log.app.notice("Dictation switch: audio not rangeable, transcribing the whole recording")
                    let last = switcher.engines.last ?? engine
                    texts = [.init(text: try await transcribeSwitchPart(last, audio: audioData, translating: target != nil),
                                   translated: false)]
                    break parts
                }
                texts.append(.init(text: try await transcribeSwitchPart(engine, audio: slice, translating: target != nil),
                                   translated: false))
            }
        }
        if let target {
            for index in texts.indices where !texts[index].translated && !texts[index].text.isEmpty {
                let step = await ByokTranslationStep.translate(
                    texts[index].text, targetLanguage: target, translator: DidunyTextTranslationService())
                texts[index] = .init(text: step.text, translated: step.translated)
            }
        }
        let text = DictationSwitchPlan.compose(texts.map(\.text))
        Log.app.info("Dictation switch: \(texts.count) parts, \(text.count) chars")
        return RealtimeSessionStopResult(
            text: text, preFinalizeText: text, optimisticCleanedText: nil, finalizeResult: start.finalizeResult)
    }

    /// True when the recording ran on an engine that keeps audio on this Mac or uses the user's own key.
    var dictationSwitchUsedOwnEngine: Bool {
        guard let switcher = dictationEngineSwitch, switcher.didSwitch else { return false }
        return switcher.engines.contains { $0 != .didunyCloud }
    }

    /// One part with exactly this engine. Never falls back to another engine, so a local pick stays local.
    private func transcribeSwitchPart(_ engine: EngineID, audio: Data, translating: Bool) async throws -> String {
        do {
            switch engine {
            case .parakeet, .appleSpeech:
                guard let local = OnDeviceEngines.engine(id: engine.rawValue) else {
                    throw TranscriptionError.apiError(String(localized: "The selected on-device engine isn't ready on this Mac. Your recording is saved."))
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("diduny-local-\(UUID().uuidString).wav")
                try audio.write(to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                let pair = activeTranslationLanguagePair ?? SettingsStorage.shared.resolveTranslationLanguagePair()
                let hints = translating ? SettingsStorage.shared.translationLanguageHints(for: pair) : SettingsStorage.shared.speechLanguageHints
                return try await local.transcribe(url, language: hints.first ?? BenchmarkRunner.defaultLanguage).text
            case .whisper:
                return try await whisperTranscriptionService.transcribe(audioData: audio)
            case .elevenLabs:
                return try await transcribeWithElevenLabsBatch(audioData: audio)
            case .didunyCloud:
                return try await transcriptionService.transcribe(audioData: audio)
            }
        } catch TranscriptionError.emptyTranscription {
            return "" // Silence after the cut: the other parts still count.
        }
    }
}
