import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) var appState
    var audioDeviceManager: AudioDeviceManager
    @Environment(\.openSettings) private var openSettings

    var onToggleRecording: @MainActor () -> Void
    var onToggleTranslationRecording: @MainActor () -> Void
    var onToggleMeetingRecording: @MainActor () -> Void
    var onSelectDevice: @MainActor (AudioDevice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Recording toggle
            Button(action: onToggleRecording) {
                HStack {
                    Text(recordingButtonTitle)
                    Spacer()
                    Text("⌘⇧D")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(isDictationButtonDisabled)

            Button(action: onToggleTranslationRecording) {
                HStack {
                    Text(translateButtonTitle)
                    Spacer()
                    Text("⌘⇧T")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(isTranslationButtonDisabled)

            // Meeting recording toggle
            Button(action: onToggleMeetingRecording) {
                HStack {
                    Text(meetingButtonTitle)
                    Spacer()
                    Text("⌘⇧M")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(isMeetingButtonDisabled)

            Divider()

            // Audio device menu
            Menu("Audio Device") {
                ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                    Button {
                        onSelectDevice(device)
                    } label: {
                        HStack {
                            Text(device.name)
                            if appState.selectedDeviceID == device.id {
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
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
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
            && (isInProgress(appState.translationRecordingState) || isInProgress(appState.meetingRecordingState))
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
            && (isInProgress(appState.recordingState) || isInProgress(appState.meetingRecordingState))
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
            "Record Meeting"
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
            && (isInProgress(appState.recordingState) || isInProgress(appState.translationRecordingState))
    }
}
