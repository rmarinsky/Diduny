import KeyboardShortcuts
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) var appState
    var audioDeviceManager: AudioDeviceManager

    var onToggleRecording: @MainActor () -> Void
    var onToggleTranslationRecording: @MainActor () -> Void
    var onToggleMeetingRecording: @MainActor () -> Void
    var onToggleMeetingTranslationRecording: @MainActor () -> Void
    var onTranscribeFile: @MainActor () -> Void
    var onOpenMainWindow: @MainActor (MainSection) -> Void
    var onOpenTypingTest: @MainActor () -> Void
    var onCheckForUpdates: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(recordingButtonTitle, action: onToggleRecording)
                .globalKeyboardShortcut(.toggleRecording)
                .disabled(isDictationButtonDisabled)

            Button(translateButtonTitle, action: onToggleTranslationRecording)
                .globalKeyboardShortcut(.toggleTranslation)
                .disabled(isTranslationButtonDisabled)

            Button(meetingButtonTitle, action: onToggleMeetingRecording)
                .disabled(true)
                .help("Meetings is in beta. Use Recordings for saved audio.")

            Button(meetingTranslationButtonTitle, action: onToggleMeetingTranslationRecording)
                .disabled(true)
                .help("Meeting Translation is in beta.")

            Divider()

            Menu("Provider: \(currentProviderLabel)") {
                Button {
                    selectCloudMode()
                } label: {
                    HStack {
                        Text("Cloud")
                        if isCloudMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    selectLocalMode()
                } label: {
                    HStack {
                        Text("Local")
                        if !isCloudMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Menu("Microphone: \(currentMicrophoneLabel)") {
                let effectiveUID = audioDeviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID)
                Button {
                    appState.preferredDeviceUID = nil
                } label: {
                    HStack {
                        Text("System Default")
                        if effectiveUID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                    Button {
                        appState.preferredDeviceUID = device.uid
                    } label: {
                        HStack {
                            Text(deviceMenuLabel(device))
                            if effectiveUID == device.uid {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Open Diduny") {
                onOpenMainWindow(.overview)
            }

            Button("Transcribe File…", action: onTranscribeFile)
                .disabled(appState.recordingState == .processing)

            Button("Recordings") {
                onOpenMainWindow(.recordings)
            }

            Button("Typing Speed Test…", action: onOpenTypingTest)

            Divider()

            Button {
                onOpenMainWindow(.general)
            } label: {
                HStack {
                    Text("Settings")
                    Spacer()
                    Text("⌘,")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates…", action: onCheckForUpdates)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 4)
    }

    private var recordingButtonTitle: String {
        switch appState.recordingState {
        case .idle:
            "Dictation"
        case .recording:
            "Stop Dictation"
        case .processing:
            "Processing Dictation…"
        case .success:
            "Dictation"
        case .error:
            "Dictation"
        }
    }

    private func isInProgress(_ state: RecordingState) -> Bool {
        state == .recording || state == .processing
    }

    private var isDictationButtonDisabled: Bool {
        appState.recordingState == .idle
            && (isInProgress(appState.translationRecordingState)
                || isInProgress(appState.meetingRecordingState)
                || isInProgress(appState.meetingTranslationRecordingState))
    }

    private var translateButtonTitle: String {
        switch appState.translationRecordingState {
        case .idle:
            "Translation"
        case .recording:
            "Stop Translation"
        case .processing:
            "Processing Translation…"
        case .success:
            "Translation"
        case .error:
            "Translation"
        }
    }

    private var isTranslationButtonDisabled: Bool {
        appState.translationRecordingState == .idle
            && (isInProgress(appState.recordingState)
                || isInProgress(appState.meetingRecordingState)
                || isInProgress(appState.meetingTranslationRecordingState))
    }

    private var meetingButtonTitle: String {
        switch appState.meetingRecordingState {
        case .idle:
            "Meeting (Beta)"
        case .recording:
            "Stop Meeting"
        case .processing:
            "Processing Meeting…"
        case .success:
            "Meeting (Beta)"
        case .error:
            "Meeting (Beta)"
        }
    }

    private var meetingTranslationButtonTitle: String {
        switch appState.meetingTranslationRecordingState {
        case .idle:
            "Meeting Translation (Beta)"
        case .recording:
            "Stop Meeting Translation"
        case .processing:
            "Processing Meeting Translation…"
        case .success:
            "Meeting Translation (Beta)"
        case .error:
            "Meeting Translation (Beta)"
        }
    }

    private func deviceMenuLabel(_ device: AudioDevice) -> String {
        var label = device.name
        if device.transportType != .unknown, device.transportType != .builtIn {
            label += " (\(device.transportType.displayName))"
        }
        if device.isDefault {
            label += " — Default"
        }
        return label
    }

    private var currentProviderLabel: String {
        isCloudMode ? "Cloud" : "Local"
    }

    private var currentMicrophoneLabel: String {
        if let effectiveUID = audioDeviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID),
           let device = audioDeviceManager.device(forUID: effectiveUID)
        {
            return device.name
        }
        return "System Default"
    }

    private var isCloudMode: Bool {
        let settings = SettingsStorage.shared
        return settings.effectiveTranscriptionProvider == .cloud
            && settings.effectiveTranslationProvider == .cloud
    }

    private func selectCloudMode() {
        guard AuthService.shared.isLoggedIn else {
            NotchManager.shared.showInfo(message: "Log in to use cloud processing", duration: 3.0)
            onOpenMainWindow(.account)
            return
        }
        let settings = SettingsStorage.shared
        settings.transcriptionProvider = .cloud
        settings.translationProvider = .cloud
    }

    private func selectLocalMode() {
        let settings = SettingsStorage.shared
        settings.transcriptionProvider = .local
        settings.translationProvider = .local
        settings.meetingRealtimeTranscriptionEnabled = false
    }
}
