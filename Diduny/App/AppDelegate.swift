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

    /// Audio level piping to notch
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

    lazy var updaterManager = UpdaterManager()
    lazy var audioDeviceManager = AudioDeviceManager()
    lazy var audioRecorder = AudioRecorderService()
    lazy var transcriptionService = CloudTranscriptionService()
    lazy var whisperTranscriptionService = WhisperTranscriptionService()
    lazy var clipboardService = ClipboardService()
    lazy var hotkeyService = HotkeyService()
    lazy var pushToTalkService = PushToTalkService()
    lazy var translationPushToTalkService = PushToTalkService()
    lazy var meetingRecorderService = MeetingRecorderService()
    lazy var realtimeTranscriptionService = CloudRealtimeService()
    var voiceRealtimeAccumulator: RealtimeVoiceAccumulator?
    var voiceRealtimeSessionEnabled: Bool = false
    var voiceRealtimeConnectionError: String?
    var translationRealtimeAccumulator: RealtimeTranslationAccumulator?
    var translationRealtimeSessionEnabled: Bool = false
    var translationRealtimeConnectionError: String?
    var translationRealtimeConnectionTask: Task<Void, Never>?

    var activeTranscriptionService: TranscriptionServiceProtocol {
        switch SettingsStorage.shared.effectiveTranscriptionProvider {
        case .cloud: transcriptionService
        case .local: whisperTranscriptionService
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_: Notification) {
        // Start Sparkle updater (access lazy var to trigger init)
        _ = updaterManager

        setupNotchStopHandler()

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushToTalkTapCountChanged(_:)),
            name: .pushToTalkTapCountChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationPushToTalkTapCountChanged(_:)),
            name: .translationPushToTalkTapCountChanged,
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

        // Fetch remote config (non-blocking)
        Task {
            await RemoteConfigService.shared.fetchIfNeeded()
            if let msg = RemoteConfigService.shared.maintenanceMessage {
                NotchManager.shared.showInfo(message: msg, duration: 5.0)
            }
        }

        if !AuthService.shared.isLoggedIn {
            Log.app.info("[Auth] Not logged in — cloud preferences remain stored, runtime uses local fallback")
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
                    let service = activeTranscriptionService
                    text = try await service.transcribe(audioData: audioData)
                case .meeting:
                    if SettingsStorage.shared.effectiveTranscriptionProvider == .cloud {
                        text = try await transcriptionService.transcribeMeeting(audioData: audioData)
                    } else {
                        text = try await whisperTranscriptionService.transcribe(audioData: audioData)
                    }
                case .translation, .meetingTranslation:
                    let service: TranscriptionServiceProtocol = SettingsStorage.shared
                        .effectiveTranslationProvider == .local
                        ? whisperTranscriptionService : transcriptionService
                    text = try await service.translateAndTranscribe(audioData: audioData)
                }

                let copyBehavior: ClipboardCopyBehavior = switch state.recordingType {
                case .voice, .translation:
                    .cleaned
                case .meeting, .meetingTranslation:
                    .raw
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

    // MARK: - Shared Recording Helpers

    func wireDeviceLostNotification() {
        audioRecorder.onDeviceLost = {
            Task { @MainActor in
                NotchManager.shared.showInfo(message: "Microphone disconnected", duration: 2.0)
            }
        }
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

            if appState.meetingTranslationRecordingState == .recording {
                NotchManager.shared.startRecording(mode: .meetingTranslation)
                return
            }
            if appState.meetingTranslationRecordingState == .processing {
                NotchManager.shared.startProcessing(mode: .meetingTranslation)
                return
            }

            if appState.meetingRecordingState == .recording {
                NotchManager.shared.startRecording(mode: .meeting)
                return
            }
            if appState.meetingRecordingState == .processing {
                NotchManager.shared.startProcessing(mode: .meeting)
                return
            }

            let translationMode: RecordingMode = .translation(languagePair: translationPairLabel)
            if appState.translationRecordingState == .recording {
                NotchManager.shared.startRecording(mode: translationMode)
                return
            }
            if appState.translationRecordingState == .processing {
                NotchManager.shared.startProcessing(mode: translationMode)
                return
            }

            if appState.recordingState == .recording {
                NotchManager.shared.startRecording(mode: .voice)
                return
            }
            if appState.recordingState == .processing {
                NotchManager.shared.startProcessing(mode: .voice)
            }
        }
    }

    func wireMeetingRecorderStatusMessages() {
        meetingRecorderService.onStatusMessage = { [weak self] message in
            Task { @MainActor in
                NotchManager.shared.showInfo(message: message, duration: 2.0)
                self?.restoreNotchForActiveRecordingAfterInfo(delay: 2.1)
            }
        }

        meetingRecorderService.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.appState.errorMessage = error.localizedDescription
                self.appState.liveTranscriptStore?.isActive = false
                self.appState.liveTranscriptStore = nil

                if self.isStateInProgress(self.appState.meetingTranslationRecordingState) {
                    self.appState.meetingTranslationRecordingState = .error
                    self.appState.meetingTranslationRecordingStartTime = nil
                    self.handleMeetingTranslationStateChange(.error)
                } else if self.isStateInProgress(self.appState.meetingRecordingState) {
                    self.appState.meetingRecordingState = .error
                    self.appState.meetingRecordingStartTime = nil
                    self.handleMeetingStateChange(.error)
                }

                NotchManager.shared.showError(message: error.localizedDescription)
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

    func startAudioRecorderWithFallback(
        initialDevice: AudioDevice,
        logPrefix: String
    ) async throws -> AudioDevice {
        do {
            try await audioRecorder.startRecording(device: initialDevice)
            return initialDevice
        } catch let error as AudioTimeoutError {
            throw error
        } catch {
            let fallbackDevices = recordingFallbackDevices(afterFailing: initialDevice)
            guard !fallbackDevices.isEmpty else {
                throw error
            }

            Log.app.warning("\(logPrefix): primary microphone failed, trying fallback routes")

            var lastError: Error = error
            for fallbackDevice in fallbackDevices {
                do {
                    try await audioRecorder.startRecording(device: fallbackDevice)
                    let warningMessage = initialDevice.isDefault
                        ? "System Default microphone failed to start. Using \(fallbackDevice.name)."
                        : "\(initialDevice.name) failed to start. Using \(fallbackDevice.name)."
                    appState.deviceFallbackWarning = warningMessage
                    Log.app.warning("\(logPrefix): recovered by switching microphone route")
                    return fallbackDevice
                } catch let timeout as AudioTimeoutError {
                    throw timeout
                } catch {
                    lastError = error
                }
            }

            throw lastError
        }
    }

    private func recordingFallbackDevices(afterFailing failedDevice: AudioDevice) -> [AudioDevice] {
        audioDeviceManager.refreshDevices()
        let alternatives = audioDeviceManager.availableDevices.filter { $0.uid != failedDevice.uid }
        guard !alternatives.isEmpty else { return [] }

        var ordered: [AudioDevice] = []

        if !failedDevice.isDefault,
           let defaultDevice = alternatives.first(where: \.isDefault)
        {
            ordered.append(defaultDevice)
        }

        ordered.append(contentsOf: alternatives.filter(\.isBuiltInMic))
        ordered.append(contentsOf: alternatives.filter {
            !$0.isBuiltInMic && !$0.isBluetooth && !$0.isDefault
        })
        ordered.append(contentsOf: alternatives.filter(\.isBluetooth))
        ordered.append(contentsOf: alternatives)

        var seen = Set<String>()
        return ordered.filter { seen.insert($0.uid).inserted }
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

    var translationPairLabel: String {
        let a = SettingsStorage.shared.translationLanguageA.uppercased()
        let b = SettingsStorage.shared.translationLanguageB.uppercased()
        return "\(a) <-> \(b)"
    }

    func handleTranslationStateChange(_ state: RecordingState) {
        translationAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .translation(languagePair: translationPairLabel),
            currentStateGetter: { self.appState.translationRecordingState },
            stateResetter: { self.appState.translationRecordingState = $0 },
            autoResetTaskSetter: { self.translationAutoResetTask = $0 },
            successDelay: 1.5,
            errorDelay: 2.0
        )
    }

    // MARK: - Settings

    func openSettings() {
        // Trigger settings opening via AppState (observed by SwiftUI)
        appState.shouldOpenSettings = true
    }
}
