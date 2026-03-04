import AppKit
import Combine
import os
import SwiftUI

enum RecordingKind {
    case voice
    case translation
    case meeting
    case meetingTranslation

    var displayName: String {
        switch self {
        case .voice: "dictation"
        case .translation: "translation"
        case .meeting: "meeting recording"
        case .meetingTranslation: "meeting translation"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    let appState = AppState()

    // Audio level piping to notch
    var audioLevelCancellable: AnyCancellable?

    // App Nap prevention tokens
    var recordingActivityToken: NSObjectProtocol?
    var meetingActivityToken: NSObjectProtocol?
    var meetingTranslationActivityToken: NSObjectProtocol?
    var translationActivityToken: NSObjectProtocol?

    // Pipeline Tasks (stored so cancel can abort them)
    var voicePipelineTask: Task<Void, Never>?
    var translationPipelineTask: Task<Void, Never>?
    var meetingPipelineTask: Task<Void, Never>?
    var meetingTranslationPipelineTask: Task<Void, Never>?

    // Auto-reset Tasks (success/error → idle timers)
    var voiceAutoResetTask: Task<Void, Never>?
    var translationAutoResetTask: Task<Void, Never>?
    var meetingAutoResetTask: Task<Void, Never>?
    var meetingTranslationAutoResetTask: Task<Void, Never>?

    // MARK: - Services (exposed for SwiftUI access)

    lazy var audioDeviceManager = AudioDeviceManager()
    lazy var audioRecorder = AudioRecorderService()
    lazy var transcriptionService = SonioxTranscriptionService()
    lazy var whisperTranscriptionService = WhisperTranscriptionService()
    lazy var clipboardService = ClipboardService()
    lazy var hotkeyService = HotkeyService()
    lazy var pushToTalkService = PushToTalkService()
    lazy var translationPushToTalkService = PushToTalkService()
    @available(macOS 13.0, *)
    lazy var meetingRecorderService = MeetingRecorderService()
    @available(macOS 13.0, *)
    lazy var realtimeTranscriptionService = SonioxRealtimeService()
    @available(macOS 13.0, *)
    var voiceRealtimeAccumulator: RealtimeVoiceAccumulator?
    var voiceRealtimeSessionEnabled: Bool = false
    @available(macOS 13.0, *)
    var translationRealtimeAccumulator: RealtimeTranslationAccumulator?
    var translationRealtimeSessionEnabled: Bool = false

    var activeTranscriptionService: TranscriptionServiceProtocol {
        switch SettingsStorage.shared.transcriptionProvider {
        case .soniox: transcriptionService
        case .whisperLocal: whisperTranscriptionService
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_: Notification) {
        setupNotchStopHandler()

        // Auto-select system default device if none selected
        if appState.selectedDeviceID == nil, let defaultDevice = audioDeviceManager.defaultDevice {
            appState.selectedDeviceID = defaultDevice.id
        }

        // Watch for device changes and auto-select default if selected device is disconnected
        audioDeviceManager.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            // If selected device is no longer available, switch to default
            if let selectedID = self.appState.selectedDeviceID,
               !devices.contains(where: { $0.id == selectedID }) {
                self.appState.selectedDeviceID = self.audioDeviceManager.defaultDevice?.id
            }
            // If no device selected and devices are available, select default
            if self.appState.selectedDeviceID == nil, let defaultDevice = self.audioDeviceManager.defaultDevice {
                self.appState.selectedDeviceID = defaultDevice.id
            }
        }

        // Listen for push-to-talk key changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushToTalkKeyChanged(_:)),
            name: .pushToTalkKeyChanged,
            object: nil
        )

        // Listen for translation push-to-talk key changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationPushToTalkKeyChanged(_:)),
            name: .translationPushToTalkKeyChanged,
            object: nil
        )

        // Check if onboarding needs to be shown
        // Uses shouldShowOnboarding which skips for existing users with mic access
        if OnboardingManager.shared.shouldShowOnboarding {
            // Setup defaults for new users
            OnboardingManager.shared.setupDefaultsForNewUser()

            // Show onboarding window after app launch settles (more reliable for LSUIElement apps)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                OnboardingWindowController.shared.showOnboarding {
                    // Setup after onboarding completes
                    self?.setupAfterOnboarding()
                }
            }
        } else {
            // Normal startup
            setupAfterOnboarding()
        }
    }

    /// Setup that runs after onboarding completes (or if already completed)
    private func setupAfterOnboarding() {
        // Setup hotkeys and push-to-talk
        setupHotkeys()
        setupPushToTalk()
        setupTranslationPushToTalk()

        // Start double Cmd+C detector for text translation
        DoubleCopyDetector.shared.start { text in
            TextTranslationWindowController.shared.showWindow(sourceText: text)
        }

        // Check for orphaned recordings from previous crash
        checkForOrphanedRecordings()

        // Check for API key - prompt if transcription uses Soniox (translation always needs it)
        let needsSoniox = SettingsStorage.shared.transcriptionProvider == .soniox
        if needsSoniox,
           !KeychainManager.shared.hasAPIKeyFast() {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                openSettings()
            }
        }
    }

    private func checkForOrphanedRecordings() {
        if let (state, fileExists) = RecoveryStateManager.shared.hasOrphanedRecording() {
            if fileExists {
                Log.app.info("Found orphaned recording from \(state.startTime)")
                showRecoveryAlert(for: state)
            } else {
                // File doesn't exist, just clear the state
                RecoveryStateManager.shared.clearState()
            }
        }
    }

    private func showRecoveryAlert(for state: RecoveryState) {
        let alert = NSAlert()
        alert.messageText = "Recover Previous Recording?"
        alert.informativeText = "An incomplete \(state.recordingType.displayName) recording was found from \(formatDate(state.startTime)). Would you like to process it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Process")
        alert.addButton(withTitle: "Discard")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            recoverRecording(from: state)
        } else {
            discardRecovery(state: state)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func recoverRecording(from state: RecoveryState) {
        Task {
            do {
                let audioURL = URL(fileURLWithPath: state.tempFilePath)
                let audioData = try await loadAudioData(from: audioURL)
                Log.app.info("Recovered audio data: \(audioData.count) bytes")

                let text: String
                switch state.recordingType {
                case .voice:
                    var service = activeTranscriptionService
                    if SettingsStorage.shared.transcriptionProvider == .soniox {
                        guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                            throw TranscriptionError.noAPIKey
                        }
                        service.apiKey = apiKey
                    }
                    text = try await service.transcribe(audioData: audioData)
                case .meeting:
                    if SettingsStorage.shared.transcriptionProvider == .soniox {
                        guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                            throw TranscriptionError.noAPIKey
                        }
                        transcriptionService.apiKey = apiKey
                        text = try await transcriptionService.transcribeMeeting(audioData: audioData)
                    } else {
                        text = try await whisperTranscriptionService.transcribe(audioData: audioData)
                    }
                case .translation, .meetingTranslation:
                    var service: TranscriptionServiceProtocol = transcriptionService
                    guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                        throw TranscriptionError.noAPIKey
                    }
                    service.apiKey = apiKey
                    text = try await service.translateAndTranscribe(audioData: audioData, targetLanguage: "uk")
                }

                let copyBehavior: ClipboardCopyBehavior
                switch state.recordingType {
                case .voice, .translation:
                    copyBehavior = .cleaned
                case .meeting, .meetingTranslation:
                    copyBehavior = .raw
                }

                clipboardService.copy(text: text, behavior: copyBehavior)
                Log.app.info("Recovery transcription successful")

                if SettingsStorage.shared.playSoundOnCompletion {
                    NSSound(named: .init("Funk"))?.play()
                }

            } catch {
                Log.app.error("Recovery transcription failed: \(error.localizedDescription)")
            }

            // Clean up
            discardRecovery(state: state)
        }
    }

    private func discardRecovery(state: RecoveryState) {
        try? FileManager.default.removeItem(atPath: state.tempFilePath)
        RecoveryStateManager.shared.clearState()
        Log.app.info("Orphaned recording discarded")
    }

    func applicationWillTerminate(_: Notification) {
        hotkeyService.unregisterAll()
        pushToTalkService.stop()
        translationPushToTalkService.stop()
        DoubleCopyDetector.shared.stop()
        NotificationCenter.default.removeObserver(self)
    }

    func loadAudioData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    // MARK: - Cross-Mode Recording Guard

    private func setupNotchStopHandler() {
        NotchManager.shared.setStopHandler { [weak self] in
            await self?.stopActiveRecordingFromNotch()
        }
    }

    func stopActiveRecordingFromNotch() async {
        if appState.meetingTranslationRecordingState == .recording {
            await stopMeetingTranslationRecording()
            return
        }

        if appState.meetingRecordingState == .recording {
            await stopMeetingRecording()
            return
        }

        if appState.translationRecordingState == .recording {
            await stopTranslationRecording()
            return
        }

        if appState.recordingState == .recording {
            await stopRecording()
            return
        }

        Log.app.info("stopActiveRecordingFromNotch: no active recording state")
    }

    private func isStateInProgress(_ state: RecordingState) -> Bool {
        state == .recording || state == .processing
    }

    private func restoreNotchForActiveRecordingAfterInfo(delay: TimeInterval = 1.6) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }

            if self.appState.meetingRecordingState == .recording {
                NotchManager.shared.startRecording(mode: .meeting)
                return
            }
            if self.appState.meetingRecordingState == .processing {
                NotchManager.shared.startProcessing(mode: .meeting)
                return
            }

            let translationMode: RecordingMode = .translation(languagePair: "EN <-> UK")
            if self.appState.translationRecordingState == .recording {
                NotchManager.shared.startRecording(mode: translationMode)
                return
            }
            if self.appState.translationRecordingState == .processing {
                NotchManager.shared.startProcessing(mode: translationMode)
                return
            }

            if self.appState.recordingState == .recording {
                NotchManager.shared.startRecording(mode: .voice)
                return
            }
            if self.appState.recordingState == .processing {
                NotchManager.shared.startProcessing(mode: .voice)
            }
        }
    }

    private func isSettingsWindowVisible() -> Bool {
        NSApp.windows.contains { window in
            window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" && window.isVisible
        }
    }

    func refreshActivationPolicy() {
        let shouldShowInAppSwitcher = isStateInProgress(appState.meetingRecordingState) || isSettingsWindowVisible()
        NSApp.setActivationPolicy(shouldShowInAppSwitcher ? .regular : .accessory)
    }

    func canStartRecording(kind: RecordingKind) -> Bool {
        var blockers: [RecordingKind] = []

        if kind != .voice, isStateInProgress(appState.recordingState) {
            blockers.append(.voice)
        }
        if kind != .translation, isStateInProgress(appState.translationRecordingState) {
            blockers.append(.translation)
        }
        if kind != .meeting, isStateInProgress(appState.meetingRecordingState) {
            blockers.append(.meeting)
        }
        if kind != .meetingTranslation, isStateInProgress(appState.meetingTranslationRecordingState) {
            blockers.append(.meetingTranslation)
        }

        guard !blockers.isEmpty else { return true }

        let blockersText = blockers.map(\.displayName).joined(separator: ", ")
        Log.app.warning("Cannot start \(kind.displayName) while \(blockersText) is in progress")
        NotchManager.shared.showInfo(message: "Stop current recording first", duration: 1.5)
        restoreNotchForActiveRecordingAfterInfo()

        return false
    }

    // MARK: - State Change Handlers
    // Note: These are called directly from recording methods after state changes
    // Since @Observable doesn't use Combine publishers like ObservableObject

    private func handleStateChange(
        _ state: RecordingState,
        mode: RecordingMode,
        currentStateGetter: @escaping () -> RecordingState,
        stateResetter: @escaping (RecordingState) -> Void,
        autoResetTaskSetter: @escaping (Task<Void, Never>?) -> Void,
        successDelay: TimeInterval,
        errorDelay: TimeInterval
    ) {
        // Cancel any previous auto-reset timer for this mode
        autoResetTaskSetter(nil)

        switch state {
        case .recording:
            NotchManager.shared.startRecording(mode: mode)
        case .processing:
            NotchManager.shared.startProcessing(mode: mode)
        case .success:
            if let text = appState.lastTranscription {
                NotchManager.shared.showSuccess(text: text)
            } else {
                NotchManager.shared.hide()
            }
            let task = Task {
                try? await Task.sleep(for: .seconds(successDelay))
                guard !Task.isCancelled else { return }
                if currentStateGetter() == .success {
                    stateResetter(.idle)
                }
            }
            autoResetTaskSetter(task)
        case .error:
            NotchManager.shared.showError(message: appState.errorMessage ?? "Error")
            let task = Task {
                try? await Task.sleep(for: .seconds(errorDelay))
                guard !Task.isCancelled else { return }
                if currentStateGetter() == .error {
                    stateResetter(.idle)
                }
            }
            autoResetTaskSetter(task)
        case .idle:
            break
        }
    }

    func handleRecordingStateChange(_ state: RecordingState) {
        voiceAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .voice,
            currentStateGetter: { self.appState.recordingState },
            stateResetter: { self.appState.recordingState = $0 },
            autoResetTaskSetter: { self.voiceAutoResetTask = $0 },
            successDelay: 1.5,
            errorDelay: 2.0
        )
    }

    func handleMeetingStateChange(_ state: RecordingState) {
        meetingAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .meeting,
            currentStateGetter: { self.appState.meetingRecordingState },
            stateResetter: { self.appState.meetingRecordingState = $0 },
            autoResetTaskSetter: { self.meetingAutoResetTask = $0 },
            successDelay: 2.0,
            errorDelay: 2.0
        )
        refreshActivationPolicy()
    }

    func handleMeetingTranslationStateChange(_ state: RecordingState) {
        meetingTranslationAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .meetingTranslation,
            currentStateGetter: { self.appState.meetingTranslationRecordingState },
            stateResetter: { self.appState.meetingTranslationRecordingState = $0 },
            autoResetTaskSetter: { self.meetingTranslationAutoResetTask = $0 },
            successDelay: 2.0,
            errorDelay: 2.0
        )
    }

    func handleTranslationStateChange(_ state: RecordingState) {
        translationAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .translation(languagePair: "EN <-> UK"),
            currentStateGetter: { self.appState.translationRecordingState },
            stateResetter: { self.appState.translationRecordingState = $0 },
            autoResetTaskSetter: { self.translationAutoResetTask = $0 },
            successDelay: 1.5,
            errorDelay: 2.0
        )
    }

    // MARK: - Device Selection (exposed for SwiftUI)

    func selectDevice(_ device: AudioDevice) {
        appState.selectedDeviceID = device.id
    }

    // MARK: - Settings

    func openSettings() {
        // Trigger settings opening via AppState (observed by SwiftUI)
        appState.shouldOpenSettings = true
    }
}
