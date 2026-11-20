import AppKit
import LaunchAtLogin
import SwiftUI

/// Settings > General (design-spec 7.12, 05 section 2.2).
struct GeneralSettingsView: View {
    @State private var appLanguage = AppLanguage.preference()
    @State private var messageFormattingMode = SettingsStorage.shared.messageFormattingMode
    @State private var autoPaste = SettingsStorage.shared.autoPaste
    @State private var playSound = SettingsStorage.shared.playSoundOnCompletion
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var recordingFeedbackSurface = SettingsStorage.shared.recordingFeedbackSurface
    @State private var showLiveTranscriptModal = SettingsStorage.shared.showLiveTranscriptModal
    @State private var clipboard = ClipboardPageModel()
    @FocusState private var keepIsFocused: Bool
    @State private var dictationRetention = SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy
    @State private var meetingRetention = SettingsStorage.shared.meetingHistoryRetentionPolicy

    var body: some View {
        PageScaffold(title: "General", subtitle: "How the app behaves, whatever the mode.") {
            VStack(alignment: .leading, spacing: 0) {
                topGroup
                GeneralMicrophoneGroup()
                afterRecordingGroup
                whileRecordingGroup
                permissionsGroup
                historyGroup
                clipboardGroup
                helpGroup
            }
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            recordingFeedbackSurface = SettingsStorage.shared.recordingFeedbackSurface
            showLiveTranscriptModal = SettingsStorage.shared.showLiveTranscriptModal
            dictationRetention = SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy
            meetingRetention = SettingsStorage.shared.meetingHistoryRetentionPolicy
        }
        // An agent can change these through the settings file while the page is open.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let storage = SettingsStorage.shared
            if messageFormattingMode != storage.messageFormattingMode { messageFormattingMode = storage.messageFormattingMode }
            if playSound != storage.playSoundOnCompletion { playSound = storage.playSoundOnCompletion }
        }
        .onDisappear { clipboard.isAskingToClear = false }
    }

    // MARK: - Groups

    private var topGroup: some View {
        GeneralGroup(heading: nil) {
            SettingsLineRow(
                title: "App language",
                caption: "Restart Diduny to apply the language to all windows and menus. Recording and translation languages do not change.",
                kind: .popUp
            ) {
                Picker("App language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .accessibilityIdentifier("general.appLanguage")
                .onChange(of: appLanguage) { _, value in value.save() }
            }
            SettingsLineRow(title: "Launch at login", kind: .toggle) {
                SettingsSwitch(title: "Launch at login", isOn: $launchAtLogin)
                    .accessibilityIdentifier("general.launchAtLogin")
                    .onChange(of: launchAtLogin) { _, value in LaunchAtLogin.isEnabled = value }
            }
        }
    }

    private var afterRecordingGroup: some View {
        GeneralGroup(heading: "After a recording") {
            SettingsLineRow(title: "Paste the text where I was typing", caption: "Off: the text is only copied.", kind: .toggle) {
                SettingsSwitch(title: "Paste the text where I was typing", isOn: $autoPaste)
                    .accessibilityIdentifier("general.autoPaste")
                    .onChange(of: autoPaste) { _, value in SettingsStorage.shared.autoPaste = value }
            }
            SettingsLineRow(title: "Play a sound when done", kind: .toggle) {
                SettingsSwitch(title: "Play a sound when done", isOn: $playSound)
                    .accessibilityIdentifier("general.playSound")
                    .onChange(of: playSound) { _, value in SettingsStorage.shared.playSoundOnCompletion = value }
            }
            SettingsLineRow(title: "Message style", kind: .segmented) {
                Picker("Message style", selection: $messageFormattingMode) {
                    Text("Normal").tag(MessageFormattingMode.normal)
                    Text("For chat").tag(MessageFormattingMode.chat)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("general.messageStyle")
                .onChange(of: messageFormattingMode) { _, value in SettingsStorage.shared.messageFormattingMode = value }
            }
        }
    }

    private var whileRecordingGroup: some View {
        GeneralGroup(heading: "While recording") {
            SettingsLineRow(title: "Show the recording in", caption: "Pick how a recording looks on screen.") {
                HStack(spacing: 10) {
                    ForEach(SurfacePreviewKind.allCases, id: \.self) { kind in
                        SurfacePreviewTile(kind: kind, isSelected: GeneralSettingsActions.previewKind(for: recordingFeedbackSurface) == kind) {
                            selectSurface(GeneralSettingsActions.surface(for: kind))
                        }
                        .accessibilityIdentifier(kind == .floatingPanel ? "general.surface.compactPanel" : "general.surface.notch")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Show the recording in"))
            }
            // Today's rule (05 2.2 proposal): the Dynamic Notch has no panel to open.
            if recordingFeedbackSurface == .compactPanel {
                SettingsLineRow(title: "Open the panel when a recording starts", kind: .toggle) {
                    SettingsSwitch(title: "Open the panel when a recording starts", isOn: $showLiveTranscriptModal)
                        .accessibilityIdentifier("general.openPanelOnStart")
                        .onChange(of: showLiveTranscriptModal) { _, value in SettingsStorage.shared.showLiveTranscriptModal = value }
                }
            }
        }
    }

    private var historyGroup: some View {
        GeneralGroup(heading: "History") {
            SettingsLineRow(title: "Keep dictation and translation", kind: .popUp) {
                retentionPicker("Keep dictation and translation", selection: $dictationRetention, id: "general.keepDictation")
                    .onChange(of: dictationRetention) { _, value in
                        SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = value
                        RecordingsLibraryStorage.shared.pruneExpiredRecordings()
                    }
            }
            SettingsLineRow(title: "Keep meeting recordings", kind: .popUp) {
                retentionPicker("Keep meeting recordings", selection: $meetingRetention, id: "general.keepMeetings")
                    .onChange(of: meetingRetention) { _, value in
                        SettingsStorage.shared.meetingHistoryRetentionPolicy = value
                        RecordingsLibraryStorage.shared.pruneExpiredRecordings()
                    }
            }
            SettingsLineRow(title: "Expired history", kind: .button) {
                Button("Delete now") { RecordingsLibraryStorage.shared.pruneExpiredRecordings() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("general.deleteExpired")
            }
        }
    }

    private var permissionsGroup: some View {
        GeneralGroup(heading: "Permissions") {
            SettingsLineRow(
                title: "Permission to record system audio",
                caption: "You said no to Screen Recording earlier. Meetings need it to record the other side.",
                kind: .button,
                showsHairline: false
            ) {
                Button("Ask again") {
                    Task {
                        await GeneralSettingsActions.askAgainForScreenRecording {
                            await PermissionManager.shared.ensureScreenRecordingPermission(context: .meetingRecording)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("general.screenRecording.askAgain")
            }
        }
    }

    private static let menuVisibleRowChoices = [5, 10, 15, 20]

    /// Moved here from the Clipboard page, which opens this group with its Settings button.
    private var clipboardGroup: some View {
        GeneralGroup(heading: "Clipboard") {
            SettingsLineRow(title: "Keep the clipboard for", kind: .popUp) {
                Picker("Keep the clipboard for", selection: Binding(
                    get: { clipboard.retention }, set: { clipboard.setRetention($0) }
                )) {
                    ForEach(ClipboardRetention.allCases) { Text(verbatim: $0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .accessibilityIdentifier("clipboard.retention")
            }
            SettingsLineRow(title: "Items shown in the menu bar list", kind: .popUp) {
                Picker("Items shown in the menu bar list", selection: Binding(
                    get: { clipboard.menuVisibleRows }, set: { clipboard.setMenuVisibleRows($0) }
                )) {
                    ForEach(Self.menuVisibleRowChoices, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .accessibilityIdentifier("clipboard.menuVisibleRows")
            }
            SettingsLineRow(title: "Keep screenshots", caption: "Screenshots take more space than text.", kind: .toggle) {
                SettingsSwitch(title: "Keep screenshots", isOn: Binding(
                    get: { clipboard.keepScreenshots }, set: { clipboard.setKeepScreenshots($0) }
                ))
                .accessibilityIdentifier("clipboard.keepScreenshots")
            }
            SettingsLineRow(title: "Keep what Diduny pastes", caption: "Dictated and translated text.", kind: .toggle) {
                SettingsSwitch(title: "Keep what Diduny pastes", isOn: Binding(
                    get: { clipboard.keepDidunyPastes }, set: { clipboard.setKeepDidunyPastes($0) }
                ))
                .accessibilityIdentifier("clipboard.keepDidunyPastes")
            }
            SettingsLineRow(
                title: "Skip password managers",
                caption: "Nothing copied in 1Password, Keychain and similar apps is kept.",
                kind: .toggle
            ) {
                SettingsSwitch(title: "Skip password managers", isOn: Binding(
                    get: { clipboard.skipPasswordManagers }, set: { clipboard.setSkipPasswordManagers($0) }
                ))
                .accessibilityIdentifier("clipboard.skipPasswordManagers")
            }
            // The question is in the row itself: "Clear" becomes "Clear everything" and "Keep".
            SettingsLineRow(title: "Clear the clipboard history", kind: .button) {
                if clipboard.isAskingToClear {
                    Button(role: .destructive) { clipboard.clearEverything() } label: {
                        Text("Clear everything").foregroundStyle(DS.Palette.no)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("clipboard.clear.confirm")
                    Button("Keep") { clipboard.isAskingToClear = false }
                        .buttonStyle(.bordered)
                        .focused($keepIsFocused)
                        .accessibilityIdentifier("clipboard.clear.keep")
                } else {
                    Button(role: .destructive) {
                        clipboard.isAskingToClear = true
                        keepIsFocused = true
                    } label: {
                        Text("Clear").foregroundStyle(DS.Palette.no)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("clipboard.clear")
                }
            }
        }
    }

    private var helpGroup: some View {
        GeneralGroup(heading: "Help") {
            SettingsLineRow(title: "Setup guide", kind: .button, showsHairline: false) {
                Button("Open") {
                    OnboardingManager.shared.showFromSettings()
                    OnboardingWindowController.shared.showOnboarding()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("general.setupGuide")
            }
        }
    }

    // MARK: - Helpers

    private func retentionPicker(_ title: LocalizedStringKey, selection: Binding<HistoryRetentionPolicy>, id: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(HistoryRetentionPolicy.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
        .accessibilityIdentifier(id)
    }

    /// The selection ring changes without animation (05 2.2 Motion).
    private func selectSurface(_ surface: RecordingFeedbackSurface) {
        guard surface != recordingFeedbackSurface else { return }
        recordingFeedbackSurface = surface
        SettingsStorage.shared.recordingFeedbackSurface = surface
        EdgeCommandPanelController.shared.applySurfacePreference()
    }
}

/// Microphone: the input choice and a short test (record a few seconds, then play them back).
/// Uses the same recorder and playback as Settings > Audio.
private struct GeneralMicrophoneGroup: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioDeviceManager.self) private var deviceManager

    @StateObject private var recorder = AudioRecorderService()
    @State private var playback = AudioTestPlayback()
    @State private var clipURL: URL?
    @State private var status = ""
    @State private var testTask: Task<Void, Never>?

    private static let testSeconds = 4

    private var isTesting: Bool { testTask != nil }

    var body: some View {
        GeneralGroup(heading: "Microphone") {
            SettingsLineRow(
                title: "Input",
                caption: status.isEmpty ? "The menu bar shows the same choice" : "\(status)",
                kind: .popUp,
                showsHairline: false
            ) {
                AudioLevelBar(level: recorder.isRecording ? recorder.audioLevel : 0)
                Picker("Input", selection: inputSelection) {
                    Text("System Default").tag(String?.none)
                    ForEach(deviceManager.availableDevices) { device in
                        Text(verbatim: device.name).tag(String?.some(device.uid))
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .accessibilityIdentifier("general.input")
                Button(isTesting ? "Stop" : "Test") { isTesting ? cancelTest() : startTest() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("general.mic.test")
            }
        }
        .onAppear { playback.onFinish = { status = String(localized: "Playback finished") } }
        .onDisappear { cleanUp() }
    }

    /// A stale preferred device (unplugged) reads as System Default.
    private var inputSelection: Binding<String?> {
        Binding(
            get: { deviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID) },
            set: { appState.preferredDeviceUID = $0 }
        )
    }

    private func startTest() {
        let (device, _) = deviceManager.resolveDevice(preferredUID: appState.preferredDeviceUID)
        status = String(localized: "Recording... speak into your microphone")
        testTask = Task { @MainActor in
            defer { testTask = nil }
            do {
                try await recorder.startRecording(device: device)
                try await Task.sleep(for: .seconds(Self.testSeconds))
                let data = try await recorder.stopRecording()
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("test_recording_\(UUID().uuidString).wav")
                try data.write(to: url, options: .atomic)
                if let clipURL { try? FileManager.default.removeItem(at: clipURL) }
                clipURL = url
                try playback.play(url)
                status = String(localized: "Playing recording...")
            } catch is CancellationError {
                recorder.cancelRecording()
                status = ""
            } catch {
                recorder.cancelRecording()
                status = String(localized: "Error: \(error.localizedDescription)")
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        playback.stop()
        status = ""
    }

    private func cleanUp() {
        testTask?.cancel()
        recorder.cancelRecording()
        playback.stop()
        if let clipURL { try? FileManager.default.removeItem(at: clipURL) }
        clipURL = nil
    }
}

/// Group on a Settings page (spec 4.10): 18 above, heading 15 semibold, 2 below it, then rows.
struct GeneralGroup<Rows: View>: View {
    let heading: LocalizedStringKey?
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heading {
                Text(heading)
                    .font(DS.Font.groupHeading)
                    .foregroundStyle(DS.Palette.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)
            }
            rows()
        }
        .padding(.top, 18)
    }
}

/// Testable parts of the General page.
enum GeneralSettingsActions {
    /// "Ask again" (05 2.2): runs the request path (Diduny's explanation, the macOS prompt, then
    /// System Settings). It stores no value; `userDeclinedScreenRecording` has no control now.
    @MainActor
    static func askAgainForScreenRecording(request: @MainActor () async -> Bool) async {
        _ = await request()
    }

    static func surface(for kind: SurfacePreviewKind) -> RecordingFeedbackSurface {
        kind == .floatingPanel ? .compactPanel : .notch
    }

    static func previewKind(for surface: RecordingFeedbackSurface) -> SurfacePreviewKind {
        surface == .compactPanel ? .floatingPanel : .dynamicNotch
    }
}

#Preview {
    GeneralSettingsView()
        .environment(AppState())
        .environment(AudioDeviceManager())
        .frame(width: 757, height: 900)
}
