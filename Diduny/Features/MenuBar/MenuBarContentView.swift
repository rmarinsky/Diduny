import KeyboardShortcuts
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) var appState
    var audioDeviceManager: AudioDeviceManager
    @Environment(\.openSettings) private var openSettings
    @State private var textCleanupEnabled = SettingsStorage.shared.textCleanupEnabled
    @State private var fillerWords = SettingsStorage.shared.fillerWords

    var onToggleRecording: @MainActor () -> Void
    var onToggleTranslationRecording: @MainActor () -> Void
    var onToggleMeetingRecording: @MainActor () -> Void
    var onToggleMeetingTranslationRecording: @MainActor () -> Void
    var onSelectDevice: @MainActor (AudioDevice) -> Void

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
                                ClipboardService.shared.copy(text: text)
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

            Menu("Text Cleanup") {
                Toggle("Enable Cleanup", isOn: Binding(
                    get: { textCleanupEnabled },
                    set: { newValue in
                        textCleanupEnabled = newValue
                        SettingsStorage.shared.textCleanupEnabled = newValue
                    }
                ))

                Divider()

                Button("Add Word to Remove...") {
                    promptToAddFillerWord()
                }

                if fillerWords.isEmpty {
                    Text("No words configured")
                        .foregroundColor(.secondary)
                } else {
                    Menu("Remove Word") {
                        ForEach(fillerWords, id: \.self) { word in
                            Button(word) {
                                SettingsStorage.shared.removeFillerWord(word)
                                reloadTextCleanupSettings()
                            }
                        }
                    }
                }

                Button("Reset Defaults") {
                    SettingsStorage.shared.resetFillerWordsToDefault()
                    reloadTextCleanupSettings()
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
        .onAppear(perform: reloadTextCleanupSettings)
        .onReceive(NotificationCenter.default.publisher(for: .textCleanupSettingsChanged)) { _ in
            reloadTextCleanupSettings()
        }
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

    private func reloadTextCleanupSettings() {
        textCleanupEnabled = SettingsStorage.shared.textCleanupEnabled
        fillerWords = SettingsStorage.shared.fillerWords
    }

    private func promptToAddFillerWord() {
        let alert = NSAlert()
        alert.messageText = "Add Word to Remove"
        alert.informativeText = "This word will be removed before text is copied to clipboard."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        inputField.placeholderString = "e.g. е-е, em, ем"
        alert.accessoryView = inputField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let candidate = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SettingsStorage.shared.addFillerWord(candidate) else { return }
        reloadTextCleanupSettings()
    }
}
