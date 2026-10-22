import Foundation

@MainActor
final class DictationOverlayController {
    static let shared = DictationOverlayController()

    let store = LiveDictationOverlayStore()
    private var autoHideTask: Task<Void, Never>?
    private var outputPreviewTask: Task<Void, Never>?
    private static let maxPreviewSourceBytes = 1500
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
        beginSurfaceSession()
        cancelOutputPreview()
        store.reset(mode: mode)
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
        store.phase = .finalizing
        store.audioLevel = 0
        if usesNotch {
            NotchManager.shared.startProcessing(mode: mode)
        } else {
            showPanel()
        }
    }

    func startProcessing(mode: RecordingMode) {
        autoHideTask?.cancel()
        if store.mode != mode {
            store.mode = mode
        }
        cancelOutputPreview()
        store.phase = .processing
        store.audioLevel = 0
        if usesNotch {
            NotchManager.shared.startProcessing(mode: mode)
        } else {
            showPanel()
        }
    }

    func showSuccess(text: String) {
        autoHideTask?.cancel()
        if !text.isEmpty {
            store.finalText = text
            store.provisionalText = ""
        }
        store.phase = .pasted
        store.audioLevel = 0
        if usesNotch {
            // The notch schedules its own dismissal and ends the session.
            NotchManager.shared.showSuccess(text: text)
            endSurfaceSession()
            return
        }
        showPanel()
        if SettingsStorage.shared.autoPaste {
            scheduleAutoHide(delay: 0.8)
        }
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
        // to the red-dot tab — recording is still active.
        if EdgeCommandPanelController.shared.isLiveFeedbackMinimized {
            switch store.phase {
            case .pasted, .error:
                break
            default:
                return
            }
        }
        guard usesNotch || store.phase != .pasted || SettingsStorage.shared.autoPaste else { return }
        dismiss()
    }

    func dismiss() {
        autoHideTask?.cancel()
        cancelOutputPreview()
        autoHideTask = nil
        store.audioLevel = 0
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

    func processTokens(_ tokens: [RealtimeToken]) {
        // The notch deliberately shows no live transcript — skip the token
        // pipeline entirely so it doesn't burn CPU with no UI attached.
        guard !usesNotch else { return }
        guard !tokens.isEmpty else { return }
        store.processTokens(tokens)
        scheduleOutputPreview()
    }

    func configureOutput(native: DictationOutput, options: [DictationOutput]) {
        cancelOutputPreview()
        store.configureOutput(native: native, options: options)
    }

    func selectOutput(_ output: DictationOutput) {
        guard store.selectedOutput != output else { return }
        store.selectedOutput = output
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
        // The GET endpoint carries the text in the URL; past this the preview
        // stays on the spoken words and Stop translates the final text.
        guard store.canStop, store.selectedOutput.targetLanguage != nil,
              let source = store.outputSourceText,
              source.utf8.count <= Self.maxPreviewSourceBytes
        else { return false }
        guard let preview = store.convertedPreview else { return true }
        return preview.output != store.selectedOutput || preview.source != source
    }

    private func cancelOutputPreview() {
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
