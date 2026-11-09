import AppKit

extension EdgeCommandPanelController {
    func perform(_ action: EdgeCommandAction) {
        guard let appDelegate, let model else { return }
        if action != .batch, !model.tilesEnabled { return }

        switch action {
        case .transcribe:
            if appDelegate.appState.recordingState == .idle {
                guard appDelegate.canStartRecording(kind: .voice) else { showCollapsed(); return }
                let start = model.tileStart(.transcribe, caps: Self.engineCapabilities)
                appDelegate.appState.panelEngines[.dictation] = CommandHome.panelSelection(start, job: .dictation)
            }
            appDelegate.toggleRecording()
        case .translate:
            if appDelegate.appState.translationRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .translation) else { showCollapsed(); return }
                let start = model.tileStart(.translate, caps: Self.engineCapabilities)
                let target = start.targetLanguage ?? model.target
                appDelegate.appState.panelEngines[.dictationTranslation] = CommandHome.panelSelection(start, job: .dictationTranslation)
                Task {
                    await appDelegate.startTranslationRecording(targetLanguage: target)
                    // A refused start never leaves idle: a later hotkey start must not inherit the pick.
                    if appDelegate.appState.translationRecordingState == .idle {
                        appDelegate.appState.panelEngines[.dictationTranslation] = nil
                    }
                }
            } else {
                appDelegate.toggleTranslationRecording()
            }
        case .meeting:
            guard appDelegate.appState.meetingRecordingState == .idle else {
                appDelegate.toggleMeetingRecording()
                return
            }
            guard appDelegate.canStartRecording(kind: .meeting) else { showCollapsed(); return }
            let start = model.tileStart(.meeting, caps: Self.engineCapabilities)
            if start.isPick, let segment = start.segment {
                // The segment follows the picked engine (02 section 8 step 0).
                appDelegate.startMeeting(appDelegate.meetingStartRoute(
                    segment: segment,
                    override: ModeEngineRules.selection(engine: start.engine, job: .meeting, segment: segment)
                ))
            } else {
                appDelegate.toggleMeetingRecording()
            }
        case .translateMeeting:
            if appDelegate.appState.meetingTranslationRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .meetingTranslation) else { showCollapsed(); return }
                let start = model.tileStart(.translateMeeting, caps: Self.engineCapabilities)
                appDelegate.appState.panelEngines[.meetingTranslation] = CommandHome.panelSelection(start, job: .meetingTranslation)
                Task {
                    await appDelegate.startMeetingTranslationRecording(languagePair: start.pair)
                    if appDelegate.appState.meetingTranslationRecordingState == .idle {
                        appDelegate.appState.panelEngines[.meetingTranslation] = nil
                    }
                }
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

    // MARK: Inputs

    static func engineCapabilities(_ id: EngineID) -> EngineCapabilities? {
        ProviderRegistry.shared.module(id: id.rawValue).flatMap {
            EngineCapabilities.make($0, activeWhisperModel: WhisperModelManager.shared.selectedModel())
        }
    }

    static func engineReadiness(_ id: EngineID) -> EngineReadiness {
        LiveEngineReadinessSource().readiness(of: id)
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
