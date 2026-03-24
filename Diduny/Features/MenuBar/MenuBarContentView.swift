import KeyboardShortcuts
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) var appState
    var audioDeviceManager: AudioDeviceManager
    @Environment(\.openSettings) private var openSettings

    var onToggleRecording: @MainActor () -> Void
    var onToggleTranslationRecording: @MainActor () -> Void
    var onToggleMeetingRecording: @MainActor () -> Void
    var onToggleMeetingTranslationRecording: @MainActor () -> Void
    var onTranscribeFile: @MainActor () -> Void
    var onCheckForUpdates: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Recording toggle
            Button(recordingButtonTitle, action: onToggleRecording)
            .globalKeyboardShortcut(.toggleRecording)
            .disabled(isDictationButtonDisabled)

            Button(translateButtonTitle, action: onToggleTranslationRecording)
            .globalKeyboardShortcut(.toggleTranslation)
            .disabled(isTranslationButtonDisabled)

            // Meeting recording toggle
            Button(meetingButtonTitle, action: onToggleMeetingRecording)
            .globalKeyboardShortcut(.toggleMeetingRecording)
            .disabled(isMeetingButtonDisabled)

            // Meeting translation toggle
            Button(meetingTranslationButtonTitle, action: onToggleMeetingTranslationRecording)
            .globalKeyboardShortcut(.toggleMeetingTranslation)
            .disabled(isMeetingTranslationButtonDisabled)

            Divider()

            // Transcribe file from disk
            Button("Transcribe File...", action: onTranscribeFile)
                .disabled(appState.recordingState == .processing)

            // Processing mode switcher
            Menu("Processing Mode") {
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
                        Text("Local (Whisper)")
                        if !isCloudMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            // Audio device menu
            Menu("Audio Device") {
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

            // Recent Transcriptions
            Menu("Recent Transcriptions") {
                let recent = RecordingsLibraryStorage.shared.recordings
                    .filter { $0.transcriptionText != nil && !$0.transcriptionText!.isEmpty }
                    .prefix(5)

                if recent.isEmpty {
                    Text("No transcriptions yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(recent)) { recording in
                        Button {
                            if let text = recording.transcriptionText {
                                ClipboardService.shared.copy(text: text, behavior: recording.type.clipboardCopyBehavior)
                            }
                        } label: {
                            let preview = transcriptionPreview(recording.transcriptionText ?? "")
                            Text(preview)
                        }
                    }

                    Divider()

                    Button("View All...") {
                        RecordingsLibraryWindowController.shared.showWindow()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
            }

            // Recordings library
            Button("Recordings") {
                RecordingsLibraryWindowController.shared.showWindow()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Button("Check for Updates...", action: onCheckForUpdates)

            Divider()

            // Settings
            Button {
                openSettings()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    NSApp.activate(ignoringOtherApps: true)
                }
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

            Divider()

            // Quit
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
            "Start Dictation"
        case .recording:
            "Stop Dictation"
        case .processing:
            "Processing..."
        case .success:
            "Transcribed"
        case .error:
            "Transcription Error"
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
            "Start Translation"
        case .recording:
            "Stop Translation"
        case .processing:
            "Translating..."
        case .success:
            "Translated"
        case .error:
            "Translation Error"
        }
    }

    private var isTranslationButtonDisabled: Bool {
        appState.translationRecordingState == .idle
            && (isInProgress(appState.recordingState)
                || isInProgress(appState.meetingRecordingState)
                || isInProgress(appState.meetingTranslationRecordingState))
    }

    private func transcriptionPreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 40 {
            return String(trimmed.prefix(40)) + "..."
        }
        return trimmed
    }

    private var meetingButtonTitle: String {
        switch appState.meetingRecordingState {
        case .idle:
            "Transcribe Meeting"
        case .recording:
            "Stop Meeting"
        case .processing:
            "Processing Meeting..."
        case .success:
            "Meeting Recorded"
        case .error:
            "Meeting Error"
        }
    }

    private var isMeetingButtonDisabled: Bool {
        appState.meetingRecordingState == .idle
            && (isInProgress(appState.recordingState)
                || isInProgress(appState.translationRecordingState)
                || isInProgress(appState.meetingTranslationRecordingState))
    }

    private var meetingTranslationButtonTitle: String {
        switch appState.meetingTranslationRecordingState {
        case .idle:
            "Translate Meeting"
        case .recording:
            "Stop Translation"
        case .processing:
            "Translating Meeting..."
        case .success:
            "Meeting Translated"
        case .error:
            "Meeting Translation Error"
        }
    }

    private var isMeetingTranslationButtonDisabled: Bool {
        appState.meetingTranslationRecordingState == .idle
            && (isInProgress(appState.recordingState)
                || isInProgress(appState.translationRecordingState)
                || isInProgress(appState.meetingRecordingState))
    }

    private func deviceMenuLabel(_ device: AudioDevice) -> String {
        var label = device.name
        if device.transportType != .unknown && device.transportType != .builtIn {
            label += " (\(device.transportType.displayName))"
        }
        if device.isDefault {
            label += " — Default"
        }
        return label
    }

    // MARK: - Processing Mode

    private var isCloudMode: Bool {
        let settings = SettingsStorage.shared
        return settings.transcriptionProvider == .cloud
            && settings.translationProvider == .cloud
            && settings.meetingRealtimeTranscriptionEnabled
    }

    private func selectCloudMode() {
        guard AuthService.shared.isLoggedIn else {
            NotchManager.shared.showInfo(message: "Log in to use cloud processing", duration: 3.0)
            appState.settingsTabToOpen = .account
            appState.shouldOpenSettings = true
            return
        }
        let settings = SettingsStorage.shared
        settings.transcriptionProvider = .cloud
        settings.translationProvider = .cloud
        settings.meetingRealtimeTranscriptionEnabled = true
    }

    private func selectLocalMode() {
        let settings = SettingsStorage.shared
        settings.transcriptionProvider = .local
        settings.translationProvider = .local
        settings.meetingRealtimeTranscriptionEnabled = false
    }

}
