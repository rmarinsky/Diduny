import AppKit

extension EdgeCommandPanelController {
    func perform(_ action: EdgeCommandAction) {
        guard let appDelegate, let model else { return }
        if action != .batch, !model.tilesEnabled { return }

        switch action {
        case .transcribe:
            if appDelegate.appState.recordingState == .idle {
                guard appDelegate.canStartRecording(kind: .voice) else { showCollapsed(); return }
                _ = model.consumeStart(.transcribe, caps: Self.engineCapabilities)
            }
            appDelegate.toggleRecording()
        case .translate:
            if appDelegate.appState.translationRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .translation) else { showCollapsed(); return }
                let start = model.consumeStart(.translate, caps: Self.engineCapabilities)
                let pair = CommandHome.translatePair(
                    target: start.targetLanguage ?? model.target, pair: model.pair, yourLanguages: model.yourLanguages
                )
                Task { await appDelegate.startTranslationRecording(languagePair: pair) }
            } else {
                appDelegate.toggleTranslationRecording()
            }
        case .meeting:
            guard appDelegate.appState.meetingRecordingState == .idle else {
                appDelegate.toggleMeetingRecording()
                return
            }
            guard appDelegate.canStartRecording(kind: .meeting) else { showCollapsed(); return }
            let start = model.consumeStart(.meeting, caps: Self.engineCapabilities)
            if start.isPick {
                // The segment follows the picked engine (02 section 8 step 0).
                appDelegate.toggleMeetingRecording(provider: start.segment == .cloud ? .cloud : .local)
            } else {
                appDelegate.toggleMeetingRecording()
            }
        case .translateMeeting:
            if appDelegate.appState.meetingTranslationRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .meetingTranslation) else { showCollapsed(); return }
                let start = model.consumeStart(.translateMeeting, caps: Self.engineCapabilities)
                Task { await appDelegate.startMeetingTranslationRecording(languagePair: start.pair) }
            } else {
                appDelegate.toggleMeetingTranslationRecording()
            }
        case .batch:
            appDelegate.batchFilesAndURLs()
            showCollapsed()
        }
    }

    /// Engine menu pick. Never writes Settings (decision 1).
    func pickEngineRow(_ rowID: String) {
        if rowID == CommandHome.providersRowID {
            appDelegate?.openMainWindow(section: .providers)
            return
        }
        model?.pickEngine(rowID: rowID)
    }

    // MARK: Inputs until WP-17 lands

    static func engineCapabilities(_ id: EngineID) -> EngineCapabilities? {
        ProviderRegistry.shared.module(id: id.rawValue).flatMap {
            EngineCapabilities.make($0, activeWhisperModel: WhisperModelManager.shared.selectedModel())
        }
    }

    /// Only what decides a row's presence today: a missing key and Parakeet on an Intel Mac.
    static func engineReadiness(_ id: EngineID) -> EngineReadiness {
        guard let module = ProviderRegistry.shared.module(id: id.rawValue) else { return .unavailable }
        if module.requiresKey, !ProviderKeyStore.shared.hasKey(for: module.id) { return .needsKey }
        if id == .parakeet, !ParakeetModelStore.isSupportedHardware { return .unsupportedHardware }
        return .ready
    }

    /// Per-mode defaults from Settings > Modes (WP-13, ADR-0012 D4), with the meeting "Starts in".
    static func currentDefaults() -> CommandHomeDefaults {
        let modeDefaults = SettingsStorage.shared.modeDefaults
        let segment = modeDefaults.meetingStartsIn
        return CommandHomeDefaults(
            dictation: modeDefaults.engine(for: .dictation),
            translation: modeDefaults.engine(for: .dictationTranslation),
            meetingSegment: segment,
            meetingEngine: modeDefaults.engine(for: segment),
            translateMeeting: modeDefaults.engine(for: .meetingTranslation)
        )
    }
}
