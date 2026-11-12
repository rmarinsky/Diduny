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
    @State private var typingSpeedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
    @State private var dictationRetention = SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy
    @State private var meetingRetention = SettingsStorage.shared.meetingHistoryRetentionPolicy

    var body: some View {
        PageScaffold(title: "General", subtitle: "How the app behaves, whatever the mode.") {
            VStack(alignment: .leading, spacing: 0) {
                topGroup
                afterRecordingGroup
                whileRecordingGroup
                historyGroup
                AgentsGroup()
                helpGroup
            }
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            recordingFeedbackSurface = SettingsStorage.shared.recordingFeedbackSurface
            showLiveTranscriptModal = SettingsStorage.shared.showLiveTranscriptModal
            typingSpeedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
            dictationRetention = SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy
            meetingRetention = SettingsStorage.shared.meetingHistoryRetentionPolicy
        }
        // An agent can change these through the settings file while the page is open.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let storage = SettingsStorage.shared
            if messageFormattingMode != storage.messageFormattingMode { messageFormattingMode = storage.messageFormattingMode }
            if playSound != storage.playSoundOnCompletion { playSound = storage.playSoundOnCompletion }
        }
        .onReceive(NotificationCenter.default.publisher(for: .typingSpeedSettingsChanged)) { _ in
            typingSpeedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
        }
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

    private var helpGroup: some View {
        GeneralGroup(heading: "Help") {
            SettingsLineRow(title: "Setup guide", kind: .button) {
                Button("Open") {
                    OnboardingManager.shared.showFromSettings()
                    OnboardingWindowController.shared.showOnboarding()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("general.setupGuide")
            }
            SettingsLineRow(
                title: "Permission to record system audio",
                caption: "You said no to Screen Recording earlier. Meetings need it to record the other side.",
                kind: .button
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
            SettingsLineRow(title: "Typing speed", kind: .button, showsHairline: false) {
                Text("\(String(format: "%.0f", typingSpeedWordsPerMinute)) WPM")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("general.typingSpeed")
                Button("Typing test") { MainWindowController.shared.showWindow(section: .typingTest) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("general.typingTest")
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

/// Agents: the `diduny` command, the skill for Claude Code and Codex, and the settings file.
private struct AgentsGroup: View {
    @State private var installed = AgentCommandLineTool.isInstalled
    @State private var installSkill = AgentSkillInstaller.isEnabled
    @State private var installError: String?

    private var agentNames: String {
        let names = AgentSkillInstaller.targets.map(\.agent)
        return names.isEmpty ? String(localized: "none found on this Mac") : names.joined(separator: ", ")
    }

    var body: some View {
        GeneralGroup(heading: "Agents") {
            SettingsLineRow(
                title: "Command line tool",
                caption: installed
                    ? "Installed as \(AgentCommandLineTool.commandName) in ~/.local/bin. Agents such as Claude Code and Codex use it to read your meetings and, when you ask them, to add to notes or tag recordings."
                    : "Lets Claude Code, Codex and other agents on this Mac read your meetings. When you ask, they can add to notes, tag recordings and transcribe again; they never delete anything.",
                kind: .button
            ) {
                if installed {
                    Button("Remove") {
                        AgentCommandLineTool.uninstall()
                        installed = AgentCommandLineTool.isInstalled
                        AgentSkillInstaller.sync()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Install command line tool") {
                        do {
                            try AgentCommandLineTool.install()
                            installError = nil
                        } catch {
                            installError = String(localized: "Could not install: \(AgentCommandLineTool.linkURL.path) already exists and is not Diduny's.")
                        }
                        installed = AgentCommandLineTool.isInstalled
                        AgentSkillInstaller.sync()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("general.agents.installCLI")
                }
            }
            if let installError {
                Text(installError).font(DS.Font.meta).foregroundStyle(.red)
            }
            SettingsLineRow(
                title: "Teach agents about Diduny",
                caption: "Adds a short Diduny skill to Claude Code and Codex, so they know how to find and read your meetings. Agents here: \(agentNames).",
                kind: .toggle
            ) {
                SettingsSwitch(title: "Teach agents about Diduny", isOn: $installSkill)
                    .accessibilityIdentifier("general.agents.skill")
                    .onChange(of: installSkill) { _, value in
                        AgentSkillInstaller.isEnabled = value
                        AgentSkillInstaller.sync()
                    }
            }
            SettingsLineRow(
                title: "Settings agents can change",
                caption: "Transcription words, languages, filler words, silence stop and sounds. Addresses, hotkeys, devices and history stay here.",
                kind: .button,
                showsHairline: false
            ) {
                Button("Show the file") {
                    NSWorkspace.shared.activateFileViewerSelecting([AgentSettingsSync.shared.fileURL])
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear { installed = AgentCommandLineTool.isInstalled }
    }
}

/// Group on a Settings page (spec 4.10): 18 above, heading 15 semibold, 2 below it, then rows.
private struct GeneralGroup<Rows: View>: View {
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
        .frame(width: 757, height: 900)
}
