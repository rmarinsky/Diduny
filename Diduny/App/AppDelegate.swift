import AppKit
import AVFoundation
import Combine
import os
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    let appState = AppState()
    private var cancellables = Set<AnyCancellable>()

    // App Nap prevention tokens
    var recordingActivityToken: NSObjectProtocol?
    var meetingActivityToken: NSObjectProtocol?
    var translationActivityToken: NSObjectProtocol?

    // MARK: - Services (exposed for SwiftUI access)

    lazy var audioDeviceManager = AudioDeviceManager()
    lazy var audioRecorder = AudioRecorderService()
    lazy var transcriptionService = SonioxTranscriptionService()
    lazy var clipboardService = ClipboardService()
    lazy var hotkeyService = HotkeyService()
    lazy var pushToTalkService = PushToTalkService()
    lazy var translationPushToTalkService = PushToTalkService()
    @available(macOS 13.0, *)
    lazy var meetingRecorderService = MeetingRecorderService()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_: Notification) {
        // Auto-select system default device if none selected
        if appState.selectedDeviceID == nil, let defaultDevice = audioDeviceManager.defaultDevice {
            appState.selectedDeviceID = defaultDevice.id
        }

        // Watch for device changes and auto-select default if selected device is disconnected
        audioDeviceManager.$availableDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
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
            .store(in: &cancellables)

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

        // Setup hotkeys and push-to-talk immediately
        // Permissions will be requested on-demand when user tries to record
        setupHotkeys()
        setupPushToTalk()
        setupTranslationPushToTalk()

        // Check for orphaned recordings from previous crash
        checkForOrphanedRecordings()

        // Check for API key
        if KeychainManager.shared.getSonioxAPIKey() == nil {
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
                let audioData = try Data(contentsOf: URL(fileURLWithPath: state.tempFilePath))
                Log.app.info("Recovered audio data: \(audioData.count) bytes")

                guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                    throw TranscriptionError.noAPIKey
                }

                transcriptionService.apiKey = apiKey

                let text: String
                switch state.recordingType {
                case .voice, .meeting:
                    text = try await transcriptionService.transcribe(audioData: audioData)
                case .translation:
                    text = try await transcriptionService.translateAndTranscribe(audioData: audioData)
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
    }

    // MARK: - State Change Handlers
    // Note: These are called directly from recording methods after state changes
    // Since @Observable doesn't use Combine publishers like ObservableObject

    func handleRecordingStateChange(_ state: RecordingState) {
        switch state {
        case .recording:
            NotchManager.shared.startRecording(mode: .voice)
        case .processing:
            NotchManager.shared.startProcessing(mode: .voice)
        case .success:
            if let text = appState.lastTranscription {
                NotchManager.shared.showSuccess(text: text)
            }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if self.appState.recordingState == .success {
                    self.appState.recordingState = .idle
                }
            }
        case .error:
            NotchManager.shared.showError(message: appState.errorMessage ?? "Error")
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.appState.recordingState == .error {
                    self.appState.recordingState = .idle
                }
            }
        case .idle:
            break
        }
    }

    func handleMeetingStateChange(_ state: MeetingRecordingState) {
        switch state {
        case .recording:
            NotchManager.shared.startRecording(mode: .meeting)
        case .processing:
            NotchManager.shared.startProcessing(mode: .meeting)
        case .success:
            if let text = appState.lastTranscription {
                NotchManager.shared.showSuccess(text: text)
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.appState.meetingRecordingState == .success {
                    self.appState.meetingRecordingState = .idle
                }
            }
        case .error:
            NotchManager.shared.showError(message: appState.errorMessage ?? "Error")
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.appState.meetingRecordingState == .error {
                    self.appState.meetingRecordingState = .idle
                }
            }
        case .idle:
            break
        }
    }

    func handleTranslationStateChange(_ state: TranslationRecordingState) {
        switch state {
        case .recording:
            NotchManager.shared.startRecording(mode: .translation)
        case .processing:
            NotchManager.shared.startProcessing(mode: .translation)
        case .success:
            if let text = appState.lastTranscription {
                NotchManager.shared.showSuccess(text: text)
            }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if self.appState.translationRecordingState == .success {
                    self.appState.translationRecordingState = .idle
                }
            }
        case .error:
            NotchManager.shared.showError(message: appState.errorMessage ?? "Error")
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.appState.translationRecordingState == .error {
                    self.appState.translationRecordingState = .idle
                }
            }
        case .idle:
            break
        }
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
