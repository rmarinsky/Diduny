import AppKit
import AVFoundation
import Combine
import os
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    let appState = AppState()

    // Audio level piping to notch
    var audioLevelCancellable: AnyCancellable?

    // App Nap prevention tokens
    var recordingActivityToken: NSObjectProtocol?
    var meetingActivityToken: NSObjectProtocol?
    var translationActivityToken: NSObjectProtocol?

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
    var micEngine: AVAudioEngine?
    let micBufferLock = NSLock()
    var micAudioBuffer = Data()
    lazy var ambientListeningService = AmbientListeningService()

    var activeTranscriptionService: TranscriptionServiceProtocol {
        switch SettingsStorage.shared.transcriptionProvider {
        case .soniox: transcriptionService
        case .whisperLocal: whisperTranscriptionService
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_: Notification) {
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

        // Listen for ambient listening settings changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ambientListeningSettingsChanged(_:)),
            name: .ambientListeningSettingsChanged,
            object: nil
        )

        // Check if onboarding needs to be shown
        // Uses shouldShowOnboarding which skips for existing users with mic access
        if OnboardingManager.shared.shouldShowOnboarding {
            // Setup defaults for new users
            OnboardingManager.shared.setupDefaultsForNewUser()

            // Show onboarding window
            OnboardingWindowController.shared.showOnboarding { [weak self] in
                // Setup after onboarding completes
                self?.setupAfterOnboarding()
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

        // Start ambient listening if enabled
        setupAmbientListening()

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
        alert.informativeText = "An incomplete \(state.recordingType.rawValue) recording was found from \(formatDate(state.startTime)). Would you like to try to transcribe it?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Transcribe")
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
                case .voice, .meeting:
                    var service = activeTranscriptionService
                    if SettingsStorage.shared.transcriptionProvider == .soniox {
                        guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                            throw TranscriptionError.noAPIKey
                        }
                        service.apiKey = apiKey
                    }
                    text = try await service.transcribe(audioData: audioData)
                case .translation:
                    var service: TranscriptionServiceProtocol = transcriptionService
                    guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                        throw TranscriptionError.noAPIKey
                    }
                    service.apiKey = apiKey
                    text = try await service.translateAndTranscribe(audioData: audioData)
                }

                clipboardService.copy(text: text)
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
        ambientListeningService.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc func ambientListeningSettingsChanged(_: Notification) {
        Log.app.info("Ambient listening settings changed - reconfiguring")
        setupAmbientListening(restart: true)
    }

    func setupAmbientListening(restart: Bool = false) {
        ambientListeningService.onWakeWordDetected = { [weak self] in
            self?.toggleRecording()
        }

        if restart {
            ambientListeningService.stop()
        }

        if SettingsStorage.shared.ambientListeningEnabled {
            ambientListeningService.start()
        } else {
            ambientListeningService.stop()
        }

        appState.ambientListeningActive = ambientListeningService.isListening
    }

    func loadAudioData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    // MARK: - State Change Handlers
    // Note: These are called directly from recording methods after state changes
    // Since @Observable doesn't use Combine publishers like ObservableObject

    private func handleStateChange(
        _ state: RecordingState,
        mode: RecordingMode,
        currentStateGetter: @escaping () -> RecordingState,
        stateResetter: @escaping (RecordingState) -> Void,
        successDelay: TimeInterval,
        errorDelay: TimeInterval
    ) {
        switch state {
        case .recording:
            NotchManager.shared.startRecording(mode: mode)
        case .processing:
            NotchManager.shared.startProcessing(mode: mode)
        case .success:
            if let text = appState.lastTranscription {
                NotchManager.shared.showSuccess(text: text)
            }
            Task {
                try? await Task.sleep(for: .seconds(successDelay))
                if currentStateGetter() == .success {
                    stateResetter(.idle)
                }
            }
        case .error:
            NotchManager.shared.showError(message: appState.errorMessage ?? "Error")
            Task {
                try? await Task.sleep(for: .seconds(errorDelay))
                if currentStateGetter() == .error {
                    stateResetter(.idle)
                }
            }
        case .idle:
            break
        }
    }

    func handleRecordingStateChange(_ state: RecordingState) {
        handleStateChange(
            state,
            mode: .voice,
            currentStateGetter: { self.appState.recordingState },
            stateResetter: { self.appState.recordingState = $0 },
            successDelay: 1.5,
            errorDelay: 2.0
        )
    }

    func handleMeetingStateChange(_ state: RecordingState) {
        handleStateChange(
            state,
            mode: .meeting,
            currentStateGetter: { self.appState.meetingRecordingState },
            stateResetter: { self.appState.meetingRecordingState = $0 },
            successDelay: 2.0,
            errorDelay: 2.0
        )
    }

    func handleTranslationStateChange(_ state: RecordingState) {
        handleStateChange(
            state,
            mode: .translation(languagePair: "EN <-> UK"),
            currentStateGetter: { self.appState.translationRecordingState },
            stateResetter: { self.appState.translationRecordingState = $0 },
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
