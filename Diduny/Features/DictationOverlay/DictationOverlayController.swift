import Foundation

@MainActor
final class DictationOverlayController {
    static let shared = DictationOverlayController()

    let store = LiveDictationOverlayStore()
    private var autoHideTask: Task<Void, Never>?
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
            return
        }
        guard usesNotch || store.phase != .pasted || SettingsStorage.shared.autoPaste else { return }
        dismiss()
    }

    func dismiss() {
        autoHideTask?.cancel()
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
