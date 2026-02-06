import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) var appState
    @ObservedObject var audioDeviceManager: AudioDeviceManager
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

            // Settings
            Button {
                openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
            "Transcribe me"
        case .recording:
            "Stop listening"
        case .processing:
            "Processing?"
        case .success:
            "Transcribed!"
        case .error:
            "Error :/"
        }
    }

    private var translateButtonTitle: String {
        switch appState.translationRecordingState {
        case .idle:
            "Translate me"
        case .recording:
            "Stop listening"
        case .processing:
            "Processing?"
        case .success:
            "Translated!"
        case .error:
            "Error :/"
        }
    }

    private var meetingButtonTitle: String {
        switch appState.meetingRecordingState {
        case .idle:
            "Record Meeting"
        case .recording:
            "Stop Meeting Recording"
        case .processing:
            "Processing Meeting?"
        case .success:
            "Meeting Welldone!"
        case .error:
            "Meeting Error :/"
        }
    }
}
