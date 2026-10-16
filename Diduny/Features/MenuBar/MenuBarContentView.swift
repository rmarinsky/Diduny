import KeyboardShortcuts
import SwiftUI

struct MenuBarProcessingModeSelection {
    private let settings: SettingsStorage
    private(set) var provider: TranscriptionProvider

    init(settings: SettingsStorage = .shared) {
        self.settings = settings
        provider = settings.effectiveTranscriptionProvider == .cloud
            && settings.effectiveTranslationProvider == .cloud ? .cloud : .local
    }

    mutating func refresh() {
        provider = settings.effectiveTranscriptionProvider == .cloud
            && settings.effectiveTranslationProvider == .cloud ? .cloud : .local
    }

    mutating func select(_ provider: TranscriptionProvider) {
        settings.selectProcessingProvider(provider)
        self.provider = provider
    }
}

struct MenuBarContentView: View {
    @Environment(AppState.self) var appState
    @State private var processingMode = MenuBarProcessingModeSelection()
    var audioDeviceManager: AudioDeviceManager

    var onToggleRecording: @MainActor () -> Void
    var onToggleTranslationRecording: @MainActor () -> Void
    var onToggleMeetingRecording: @MainActor () -> Void
    var onToggleMeetingTranslationRecording: @MainActor () -> Void
    var onBatchFilesAndURLs: @MainActor () -> Void
    var onOpenMainWindow: @MainActor (MainSection) -> Void
    var onCheckForUpdates: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalendarMenuItems()
            Button(recordingButtonTitle, action: onToggleRecording)
                .globalKeyboardShortcut(.toggleRecording)
                .disabled(isDictationButtonDisabled)

            Button(translateButtonTitle, action: onToggleTranslationRecording)
                .globalKeyboardShortcut(.toggleTranslation)
                .disabled(isTranslationButtonDisabled)

            Button(meetingButtonTitle, action: onToggleMeetingRecording)
                .globalKeyboardShortcut(.toggleMeetingRecording)
                .disabled(isMeetingButtonDisabled)
                .help("Record meeting audio")

            Button(meetingTranslationButtonTitle, action: onToggleMeetingTranslationRecording)
                .globalKeyboardShortcut(.toggleMeetingTranslation)
                .disabled(isMeetingTranslationButtonDisabled)
                .help("Record and translate meeting audio")

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

            Button(MainWindowController.batchComposerActionTitle, action: onBatchFilesAndURLs)
                .keyboardShortcut("b", modifiers: [.command, .shift])

            Button("Recordings") {
                onOpenMainWindow(.recordings)
            }

            Button("Typing Speed Test…") {
                onOpenMainWindow(.typingTest)
            }

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
        .onAppear { processingMode.refresh() }
    }

    private var recordingButtonTitle: String {
        switch appState.recordingState {
        case .idle:
            String(localized: "Dictation")
        case .recording:
            String(localized: "Stop Dictation")
        case .processing:
            String(localized: "Processing Dictation…")
        case .success:
            String(localized: "Dictation")
        case .error:
            String(localized: "Dictation")
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
            String(localized: "Translation \(translationTargetLabel)")
        case .recording:
            String(localized: "Stop Translation")
        case .processing:
            String(localized: "Processing Translation…")
        case .success:
            String(localized: "Translation \(translationTargetLabel)")
        case .error:
            String(localized: "Translation \(translationTargetLabel)")
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
            String(localized: "Meeting")
        case .recording:
            String(localized: "Stop Meeting")
        case .processing:
            String(localized: "Processing Meeting…")
        case .success:
            String(localized: "Meeting")
        case .error:
            String(localized: "Meeting")
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
            String(localized: "Meeting Translation \(translationTargetLabel)")
        case .recording:
            String(localized: "Stop Meeting Translation")
        case .processing:
            String(localized: "Processing Meeting Translation…")
        case .success:
            String(localized: "Meeting Translation \(translationTargetLabel)")
        case .error:
            String(localized: "Meeting Translation \(translationTargetLabel)")
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
        if device.transportType != .unknown, device.transportType != .builtIn {
            label += " (\(device.transportType.displayName))"
        }
        if device.isDefault {
            label += String(localized: " — Default")
        }
        return label
    }

    private var currentProviderLabel: String {
        isCloudMode ? "Cloud" : "Local"
    }

    private var translationTargetLabel: String {
        if SettingsStorage.shared.effectiveTranslationProvider == .local {
            return "EN"
        }
        return SettingsStorage.shared.resolveTranslationLanguagePair().displayLabel
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
        processingMode.provider == .cloud
    }

    private func selectCloudMode() {
        guard AuthService.shared.isLoggedIn else {
            DictationOverlayController.shared.showInfo(
                message: String(localized: "Log in to use cloud processing"),
                duration: 3.0
            )
            onOpenMainWindow(.account)
            return
        }
        processingMode.select(.cloud)
    }

    private func selectLocalMode() {
        processingMode.select(.local)
    }
}
