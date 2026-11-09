import Foundation

@MainActor
final class DictationOverlayController {
    static let shared = DictationOverlayController()

    let store = LiveDictationOverlayStore()
    /// The outcome after Stop for the command panel (WP-42). Kept until the next recording.
    let outcomeStore = EdgeCommandOutcomeStore()
    /// When Stop was pressed; the outcome duration ends here and a paste before it is stale.
    private var stoppedAt: Date?
    /// The meeting stop flow hands over the library id before it reports success.
    private var outcomeRecordingID: UUID?

    /// Meetings: the saved library recording, for Open recording in the outcome.
    func setOutcomeRecordingID(_ id: UUID?) {
        outcomeRecordingID = id
    }
    private var autoHideTask: Task<Void, Never>?
    private var outputPreviewTask: Task<Void, Never>?
    private var onStopRequested: (@MainActor () async -> Void)?

    /// Surface captured when a feedback session starts. A recording finishes
    /// on the surface it started on even if the setting flips mid-recording;
    /// the new choice applies from the next session.
    private var activeSurface: RecordingFeedbackSurface?

    private var currentSurface: RecordingFeedbackSurface {
        activeSurface ?? SettingsStorage.shared.recordingFeedbackSurface
    }

    private var usesNotch: Bool {
        currentSurface == .notch
    }

    private init() {}

    func setStopHandler(_ handler: (@MainActor () async -> Void)?) {
        onStopRequested = handler
    }

    func begin(mode: RecordingMode) {
        autoHideTask?.cancel()
        isNotchHandoffShowing = false
        beginSurfaceSession()
        cancelOutputPreview()
        store.reset(mode: mode)
        configureSession(mode: mode)
        stoppedAt = nil
        outcomeRecordingID = nil
        outcomeStore.clear()
        store.phase = .starting
        if usesNotch {
            NotchManager.shared.resumeRecording(mode: mode)
        } else {
            showPanel()
        }
    }

    func startRecording(mode: RecordingMode) {
        autoHideTask?.cancel()
        beginSurfaceSession()
        if store.mode != mode {
            store.reset(mode: mode)
            configureSession(mode: mode)
        }
        store.phase = .recording
        if usesNotch {
            NotchManager.shared.startRecording(mode: mode)
        } else {
            showPanel()
        }
    }

    func startFinalizing(mode: RecordingMode) {
        autoHideTask?.cancel()
        if store.mode != mode {
            store.mode = mode
        }
        cancelOutputPreview()
        stoppedAt = stoppedAt ?? Date()
        if mode.isMeeting {
            // The meeting timer stops at Stop; finalizing and the hand-off show the recorded length.
            store.endedAt = Date()
        }
        store.phase = .finalizing
        store.audioLevel = 0
        if usesNotch {
            NotchManager.shared.startProcessing(mode: mode)
        } else {
            showPanel()
        }
    }

    /// - Parameter recordingID: meetings, the library recording for Open recording.
    func showSuccess(text: String, recordingID: UUID? = nil) {
        autoHideTask?.cancel()
        if !text.isEmpty {
            store.finalText = text
            store.provisionalText = ""
        }
        recordOutcome(resultText: text.isEmpty ? store.finalText : text, recordingID: recordingID)
        store.phase = .pasted
        store.audioLevel = 0
        if usesNotch {
            // The notch schedules its own dismissal and ends the session.
            NotchManager.shared.showSuccess(text: text)
            endSurfaceSession()
            return
        }
        // Floating surface: the outcome replaces the live view and closes as the success panel did.
        let delivery = outcomeStore.outcome?.delivery ?? .copied
        // A minimized panel has no outcome on screen; only the red-dot tab, which would stay stuck.
        if EdgeCommandPanelController.shared.isLiveFeedbackMinimized, delivery != .pasted {
            dismiss()
            return
        }
        showPanel()
        if let delay = Self.outcomeAutoHideDelay(delivery: delivery) {
            scheduleAutoHide(delay: delay)
        }
    }

    /// Roman, 2026-11-09, replaces default 8: after a paste the outcome closes in 0.8 s. "Copied" (auto-paste
    /// off or a failed paste) stays until ×, New recording or the next recording.
    nonisolated static func outcomeAutoHideDelay(delivery: EdgeCommandOutcome.Delivery) -> TimeInterval? {
        delivery == .pasted ? 0.8 : nil
    }

    /// Two-way Cloud translation names the pair (WP-41 "EN ↔ UK"). One-direction engines name the
    /// target only, "→ UK" (decision 2A), as the tile caption does.
    static func meetingTranslationFlow(engine: EngineID, pair: TranslationLanguagePair) -> EdgeCommandOutcome.Flow {
        engine == .didunyCloud
            ? .meetingTranslation(pair: CommandHome.pairCodes(pair))
            : .meetingTranslation(pair: "→ " + pair.languageB.uppercased())
    }

    /// Builds the outcome for the stopped recording from the session (default 8, 02 Q11-Q12).
    private func recordOutcome(resultText: String, recordingID: UUID?) {
        let end = stoppedAt ?? store.endedAt ?? Date()
        let duration = Int(max(end.timeIntervalSince(store.startedAt), 0).rounded())
        let flow: EdgeCommandOutcome.Flow = switch store.mode {
        case .meeting:
            .meeting
        case .meetingTranslation:
            Self.meetingTranslationFlow(engine: store.meetingTranslationEngine, pair: store.meetingTranslationPair)
        default:
            if store.selectedOutput.targetLanguage != nil {
                .dictationTranslation(languageName: store.selectedOutput.label)
            } else {
                .dictation
            }
        }
        outcomeStore.show(EdgeCommandOutcome(
            flow: flow,
            durationSeconds: duration,
            delivery: Self.delivery(
                autoPaste: SettingsStorage.shared.autoPaste,
                lastPaste: ClipboardService.shared.lastPaste,
                stoppedAt: stoppedAt
            ),
            resultText: flow.isMeeting ? "" : resultText,
            recordingID: recordingID ?? outcomeRecordingID
        ))
    }

    /// Pasted only for a paste of this recording; auto-paste off or a failed or older paste is copied.
    nonisolated static func delivery(
        autoPaste: Bool,
        lastPaste: Date?,
        stoppedAt: Date?
    ) -> EdgeCommandOutcome.Delivery {
        guard autoPaste, let lastPaste else { return .copied }
        if let stoppedAt, lastPaste < stoppedAt { return .copied }
        return .pasted
    }

    func showError(message: String) {
        autoHideTask?.cancel()
        cancelOutputPreview()
        store.phase = .error(message)
        store.audioLevel = 0
        if usesNotch {
            NotchManager.shared.showError(message: message)
            endSurfaceSession()
            return
        }
        showPanel()
        scheduleAutoHide(delay: 3.0)
    }

    func showInfo(message: String, duration: TimeInterval = 1.5) {
        // Mid-recording toasts must not tear down a minimized live tab via
        // scheduleAutoHide → dismiss. Use the during-recording path instead.
        if EdgeCommandPanelController.shared.isLiveFeedbackMinimized {
            showInfoDuringRecording(message: message, mode: store.mode, duration: duration)
            return
        }
        autoHideTask?.cancel()
        cancelOutputPreview()
        store.phase = .info(message)
        store.audioLevel = 0
        if usesNotch {
            NotchManager.shared.showInfo(message: message, duration: duration)
            endSurfaceSession()
            return
        }
        showPanel()
        scheduleAutoHide(delay: duration)
    }

    /// True while the "Transcribing in background" hand-off is on screen.
    var isShowingBackgroundHandoff: Bool {
        store.backgroundHandoffDetail != nil || isNotchHandoffShowing
    }

    /// The notch shows the hand-off itself; this keeps `.success` from hiding it early.
    private var isNotchHandoffShowing = false

    /// Stop handed the meeting to the transcription queue: say so for 2 s, then close.
    func showBackgroundHandoff(duration: TimeInterval = 2.0) {
        recordOutcome(resultText: "", recordingID: nil)
        let message = String(localized: "Transcribing in background")
        autoHideTask?.cancel()
        cancelOutputPreview()
        store.audioLevel = 0
        if usesNotch {
            NotchManager.shared.showInfo(message: message, duration: duration)
            endSurfaceSession()
            isNotchHandoffShowing = true
            autoHideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.isNotchHandoffShowing = false }
            }
            return
        }
        // A panel the person minimized stays out of the way.
        if EdgeCommandPanelController.shared.isLiveFeedbackMinimized {
            dismiss()
            return
        }
        store.backgroundHandoffDetail = String(localized: "The transcript will appear in Recordings.")
        store.phase = .info(message)
        showPanel()
        scheduleAutoHide(delay: duration)
    }

    func showInfoDuringRecording(message: String, mode: RecordingMode, duration: TimeInterval = 1.5) {
        if usesNotch {
            NotchManager.shared.showInfoDuringRecording(message: message, mode: mode, duration: duration)
            return
        }
        autoHideTask?.cancel()
        let savedPhase = store.phase
        let savedStart = store.startedAt
        store.mode = mode
        store.phase = .info(message)
        showPanel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.store.startedAt = savedStart
                self.store.phase = savedPhase
                self.showPanel()
            }
        }
    }

    func hide() {
        // Toast auto-hide must not dismiss while the user hid the live panel
        // to the red-dot tab — recording is still active. Once Stop moved the
        // panel to finalizing/processing, the end of the stop must dismiss it.
        if EdgeCommandPanelController.shared.isLiveFeedbackMinimized {
            switch store.phase {
            case .starting, .recording:
                return
            default:
                break
            }
        }
        guard usesNotch || store.phase != .pasted || outcomeStore.outcome?.delivery == .pasted else { return }
        dismiss()
    }

    func dismiss() {
        outcomeStore.clear()
        autoHideTask?.cancel()
        cancelOutputPreview()
        autoHideTask = nil
        isNotchHandoffShowing = false
        store.audioLevel = 0
        store.backgroundHandoffDetail = nil
        if usesNotch {
            NotchManager.shared.hide()
        }
        // Always release the panel's live presentation too — it no-ops when
        // not shown, and covers a surface flip that happened mid-recording.
        EdgeCommandPanelController.shared.dismissLiveFeedback()
        endSurfaceSession()
    }

    func updateAudioLevel(_ level: Float) {
        let clamped = max(0, min(level, 1))
        if usesNotch {
            NotchManager.shared.audioLevel = clamped
        } else {
            store.audioLevel = clamped
        }
    }

    /// Shows (or with nil hides) the "Stop after silence" countdown on the active surface.
    func updateSilenceCountdown(_ secondsLeft: Int?) {
        if usesNotch {
            NotchManager.shared.silenceCountdown = secondsLeft
        } else {
            store.silenceCountdown = secondsLeft
        }
    }

    func processTokens(_ tokens: [RealtimeToken]) {
        // The notch deliberately shows no live transcript — skip the token
        // pipeline entirely so it doesn't burn CPU with no UI attached.
        guard !usesNotch else { return }
        guard !tokens.isEmpty else { return }
        store.processTokens(tokens)
        let output = store.selectedOutput
        store.updateVoiceCommand()
        if store.selectedOutput != output {
            cancelOutputPreview()
            scheduleOutputPreview(delay: .zero)
        } else {
            scheduleOutputPreview()
        }
    }

    func configureOutput(native: DictationOutput, options: [DictationOutput], listensForVoiceCommands: Bool) {
        cancelOutputPreview()
        store.configureOutput(native: native, options: options, listensForVoiceCommands: listensForVoiceCommands)
    }

    /// Also serves Undo: picking any output ends a spoken command for this recording.
    func selectOutput(_ output: DictationOutput) {
        guard store.selectedOutput != output || store.voiceCommand != nil else { return }
        store.pickOutput(output)
        cancelOutputPreview()
        scheduleOutputPreview(delay: .zero)
    }

    /// Text-translates the spoken words so the panel previews the selected
    /// output. Throttled to one request in flight; the paste result is
    /// produced again at Stop from the final text.
    private func scheduleOutputPreview(delay: Duration = .milliseconds(600)) {
        guard outputPreviewTask == nil, needsOutputPreview else { return }
        outputPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let output = store.selectedOutput
            guard needsOutputPreview, let target = output.targetLanguage,
                  let source = store.outputSourceText
            else {
                outputPreviewTask = nil
                return
            }
            let text = try? await TextTranslationClient.requestTranslation(
                sourceText: source,
                sourceLanguage: "auto",
                targetLanguage: target
            )
            guard !Task.isCancelled else { return }
            guard let text else {
                // Back off so a failing endpoint is not hit on every token batch.
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                outputPreviewTask = nil
                return
            }
            outputPreviewTask = nil
            store.convertedPreview = (output: output, source: source, text: text)
            // Catch up with words spoken while the request was in flight.
            scheduleOutputPreview()
        }
    }

    private var needsOutputPreview: Bool {
        guard store.canStop, store.selectedOutput.targetLanguage != nil,
              let source = store.outputSourceText, store.isPreviewable
        else { return false }
        guard let preview = store.convertedPreview else { return true }
        return preview.output != store.selectedOutput || preview.source != source
    }

    func cancelOutputPreview() {
        outputPreviewTask?.cancel()
        outputPreviewTask = nil
    }

    func markSegmentBoundary() {
        guard !usesNotch else { return }
        store.markSegmentBoundary()
    }

    func updateConnectionStatus(_ status: RealtimeConnectionStatus) {
        guard !usesNotch else { return }
        store.connectionStatus = status
    }

    /// The session's engine and the Output menu's languages, read once at start.
    private func configureSession(mode: RecordingMode) {
        store.yourLanguages = SettingsStorage.shared.yourLanguages
        let job: STTJob? = switch mode {
        case .voice: .dictation
        case .translation: .dictationTranslation
        case .meeting: .meeting
        case .meetingTranslation: .meetingTranslation
        case .fileTranscription: nil
        }
        store.sessionEngine = job.flatMap { job in
            AppDelegate.current.flatMap { LiveSessionEngine.running($0.modeRoute(for: job).selection) }
        }
    }

    private func beginSurfaceSession() {
        if activeSurface == nil {
            activeSurface = SettingsStorage.shared.recordingFeedbackSurface
        }
    }

    private func endSurfaceSession() {
        activeSurface = nil
    }

    func copyCurrentTranscript() {
        let text = store.displayText
        guard !text.isEmpty else { return }
        ClipboardService.shared.copy(text: text, behavior: .raw)
        store.markCopied()
    }

    func requestStop() {
        guard let onStopRequested else { return }
        Task { @MainActor in
            await onStopRequested()
        }
    }

    private func showPanel() {
        EdgeCommandPanelController.shared.showLiveFeedback(mode: store.mode)
    }

    private func scheduleAutoHide(delay: TimeInterval) {
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.hide()
            }
        }
    }
}
