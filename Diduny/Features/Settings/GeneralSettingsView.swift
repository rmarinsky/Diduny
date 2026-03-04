import AppKit
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

struct GeneralSettingsView: View {
    @State private var autoPaste = SettingsStorage.shared.autoPaste
    @State private var playSound = SettingsStorage.shared.playSoundOnCompletion
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var pushToTalkKey = SettingsStorage.shared.pushToTalkKey
    @State private var translationPushToTalkKey = SettingsStorage.shared.translationPushToTalkKey
    @State private var handsFreeModeEnabled = SettingsStorage.shared.handsFreeModeEnabled
    @State private var escapeCancelEnabled = SettingsStorage.shared.escapeCancelEnabled
    @State private var escapeCancelShortcut = SettingsStorage.shared.escapeCancelShortcut
    @State private var escapeCancelSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
    @State private var isRecordingEscapeCancelShortcut = false
    @State private var escapeCancelShortcutMonitor: Any?
    @State private var textCleanupEnabled = SettingsStorage.shared.textCleanupEnabled
    @State private var fillerWords = SettingsStorage.shared.fillerWords
    @State private var newFillerWord = ""
    @State private var fillerWordFeedback = ""
    @State private var fillerWordFeedbackIsError = false

    var body: some View {
        Form {
            Section {
                hotkeySection
            } header: {
                Text("Global Hotkeys")
            } footer: {
                Text("Click on a recorder to set a new shortcut. Press Escape to cancel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Key:", selection: $pushToTalkKey) {
                    ForEach(PushToTalkKey.allCases) { key in
                        Text(key.pickerLabel).tag(key)
                    }
                }
                .onChange(of: pushToTalkKey) { _, newValue in
                    SettingsStorage.shared.pushToTalkKey = newValue
                    NotificationCenter.default.post(name: .pushToTalkKeyChanged, object: newValue)
                }

                recordingModeSection
            } header: {
                Text("Push to Talk")
            }

            Section {
                Picker("Key:", selection: $translationPushToTalkKey) {
                    ForEach(PushToTalkKey.allCases) { key in
                        Text(key.pickerLabel).tag(key)
                    }
                }
                .onChange(of: translationPushToTalkKey) { _, newValue in
                    SettingsStorage.shared.translationPushToTalkKey = newValue
                    NotificationCenter.default.post(name: .translationPushToTalkKeyChanged, object: newValue)
                }
            } header: {
                Text("Translation Push to Talk")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uses the same recording mode as Push to Talk above.")
                    Text("Translation is available with Cloud (Soniox) only.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section {
                Toggle("Auto-paste transcribed text", isOn: $autoPaste)
                    .onChange(of: autoPaste) { _, newValue in
                        SettingsStorage.shared.autoPaste = newValue
                    }

                Toggle("Play sound when done", isOn: $playSound)
                    .onChange(of: playSound) { _, newValue in
                        SettingsStorage.shared.playSoundOnCompletion = newValue
                    }

                Toggle("Enable cancel shortcut during recording", isOn: $escapeCancelEnabled)
                    .onChange(of: escapeCancelEnabled) { _, newValue in
                        SettingsStorage.shared.escapeCancelEnabled = newValue
                        if !newValue {
                            EscapeCancelService.shared.deactivate()
                            stopEscapeCancelShortcutCapture()
                        }
                    }

                if escapeCancelEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("Cancel shortcut:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(isRecordingEscapeCancelShortcut ? "Press shortcut..." : escapeCancelShortcut.displayName) {
                                if isRecordingEscapeCancelShortcut {
                                    stopEscapeCancelShortcutCapture()
                                } else {
                                    startEscapeCancelShortcutCapture()
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Reset") {
                                resetEscapeCancelShortcutToDefault()
                            }
                            .disabled(isRecordingEscapeCancelShortcut || escapeCancelShortcut == .defaultShortcut)
                        }

                        Toggle("Save audio when cancelled", isOn: $escapeCancelSaveAudio)
                            .onChange(of: escapeCancelSaveAudio) { _, newValue in
                                SettingsStorage.shared.escapeCancelSaveAudio = newValue
                            }
                    }
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.isEnabled = newValue
                    }

            } header: {
                Text("Behavior")
            }

            Section {
                Toggle("Normalize text before copy", isOn: $textCleanupEnabled)
                    .onChange(of: textCleanupEnabled) { _, newValue in
                        SettingsStorage.shared.textCleanupEnabled = newValue
                    }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Add filler words (comma or new line separated)", text: $newFillerWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                addFillerWordsFromInput()
                            }
                            .onChange(of: newFillerWord) { _, _ in
                                fillerWordFeedback = ""
                            }

                        Button("Add") {
                            addFillerWordsFromInput()
                        }
                        .disabled(fillerWordCandidates.isEmpty)
                    }

                    if !fillerWordFeedback.isEmpty {
                        Text(fillerWordFeedback)
                            .font(.caption)
                            .foregroundColor(fillerWordFeedbackIsError ? .red : .secondary)
                    }
                }

                if fillerWords.isEmpty {
                    Text("No filler words configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    WrappingChipsLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(fillerWords, id: \.self) { word in
                            fillerWordChip(for: word)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button("Add English Variations") {
                        addEnglishPresetWords()
                    }
                    .disabled(!canAddEnglishPreset)

                    Button("Reset Default Words") {
                        SettingsStorage.shared.resetFillerWordsToDefault()
                        reloadTextCleanupSettings()
                        fillerWordFeedback = "Default list restored."
                        fillerWordFeedbackIsError = false
                    }
                }
            } header: {
                Text("Text Cleanup")
            } footer: {
                Text("Words are removed before copying to clipboard and before auto-paste. Use commas or new lines to add multiple words at once.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Show Welcome Tour") {
                    showOnboarding()
                }
                .buttonStyle(.link)
            } header: {
                Text("Help")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reloadBehaviorSettings()
            reloadTextCleanupSettings()
        }
        .onDisappear {
            stopEscapeCancelShortcutCapture()
        }
        .onReceive(NotificationCenter.default.publisher(for: .textCleanupSettingsChanged)) { _ in
            reloadTextCleanupSettings()
        }
    }

    private func showOnboarding() {
        // Show onboarding from settings (without resetting user's completion status)
        OnboardingManager.shared.showFromSettings()
        OnboardingWindowController.shared.showOnboarding {
            // Onboarding completed
        }
    }

    @ViewBuilder
    private func fillerWordChip(for word: String) -> some View {
        HStack(spacing: 6) {
            Text(word)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                SettingsStorage.shared.removeFillerWord(word)
                reloadTextCleanupSettings()
                fillerWordFeedback = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(4)
                    .background(Circle().fill(Color.secondary.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.32), lineWidth: 1))
    }

    private var fillerWordCandidates: [String] {
        let separators = CharacterSet(charactersIn: ",;\n")
        return newFillerWord
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canAddEnglishPreset: Bool {
        let existingKeys = Set(fillerWords.map(foldedFillerWordKey))
        return SettingsStorage.shared.englishFillerWordPreset
            .contains { !existingKeys.contains(foldedFillerWordKey($0)) }
    }

    private func foldedFillerWordKey(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func addEnglishPresetWords() {
        let addedCount = SettingsStorage.shared.addEnglishFillerWordPreset()
        reloadTextCleanupSettings()

        if addedCount > 0 {
            fillerWordFeedback = "Added \(addedCount) English variants."
            fillerWordFeedbackIsError = false
        } else {
            fillerWordFeedback = "English preset is already in the list."
            fillerWordFeedbackIsError = false
        }
    }

    private func addFillerWordsFromInput() {
        let candidates = fillerWordCandidates
        guard !candidates.isEmpty else { return }

        let addedCount = SettingsStorage.shared.addFillerWords(candidates)
        reloadTextCleanupSettings()

        if addedCount == 0 {
            fillerWordFeedback = "Nothing added: all items already exist."
            fillerWordFeedbackIsError = true
            return
        }

        newFillerWord = ""
        let skippedCount = candidates.count - addedCount
        if skippedCount > 0 {
            fillerWordFeedback = "Added \(addedCount), skipped \(skippedCount) duplicates."
        } else {
            fillerWordFeedback = "Added \(addedCount) item\(addedCount == 1 ? "" : "s")."
        }
        fillerWordFeedbackIsError = false
    }

    private func reloadTextCleanupSettings() {
        textCleanupEnabled = SettingsStorage.shared.textCleanupEnabled
        fillerWords = SettingsStorage.shared.fillerWords
    }

    private func reloadBehaviorSettings() {
        escapeCancelEnabled = SettingsStorage.shared.escapeCancelEnabled
        escapeCancelShortcut = SettingsStorage.shared.escapeCancelShortcut
        escapeCancelSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
    }

    private func startEscapeCancelShortcutCapture() {
        stopEscapeCancelShortcutCapture()
        isRecordingEscapeCancelShortcut = true

        escapeCancelShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let shortcut = RecordingCancelShortcut.from(event: event)
            SettingsStorage.shared.escapeCancelShortcut = shortcut
            escapeCancelShortcut = shortcut
            stopEscapeCancelShortcutCapture()
            return nil
        }
    }

    private func stopEscapeCancelShortcutCapture() {
        isRecordingEscapeCancelShortcut = false
        if let monitor = escapeCancelShortcutMonitor {
            NSEvent.removeMonitor(monitor)
            escapeCancelShortcutMonitor = nil
        }
    }

    private func resetEscapeCancelShortcutToDefault() {
        let shortcut = RecordingCancelShortcut.defaultShortcut
        SettingsStorage.shared.escapeCancelShortcut = shortcut
        escapeCancelShortcut = shortcut
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcribe Me:")
                    .frame(width: 160, alignment: .leading)
                KeyboardShortcuts.Recorder(for: .toggleRecording)
            }

            HStack {
                Text("Translate Me:")
                    .frame(width: 160, alignment: .leading)
                KeyboardShortcuts.Recorder(for: .toggleTranslation)
            }

            HStack {
                Text("Translate Selected Text:")
                    .frame(width: 160, alignment: .leading)
                Text("Double-press ⌘C")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Transcribe Meeting:")
                    .frame(width: 160, alignment: .leading)
                KeyboardShortcuts.Recorder(for: .toggleMeetingRecording)
            }

            HStack {
                Text("Translate Meeting:")
                    .frame(width: 160, alignment: .leading)
                KeyboardShortcuts.Recorder(for: .toggleMeetingTranslation)
            }
        }
    }

    // MARK: - Recording Mode

    private var recordingModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording Mode:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Hold to record option
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: handsFreeModeEnabled ? "circle" : "circle.inset.filled")
                    .foregroundColor(handsFreeModeEnabled ? .secondary : .accentColor)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Hold to record")
                        .fontWeight(handsFreeModeEnabled ? .regular : .medium)
                    Text("Hold key down while speaking, release to transcribe")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handsFreeModeEnabled = false
                SettingsStorage.shared.handsFreeModeEnabled = false
            }

            // Toggle mode option
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: handsFreeModeEnabled ? "circle.inset.filled" : "circle")
                    .foregroundColor(handsFreeModeEnabled ? .accentColor : .secondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Toggle mode")
                        .fontWeight(handsFreeModeEnabled ? .medium : .regular)
                    Text("Double-tap to start, double-tap again to stop")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handsFreeModeEnabled = true
                SettingsStorage.shared.handsFreeModeEnabled = true
            }
        }
        .padding(.top, 4)
    }
}

private struct WrappingChipsLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Void
    ) -> CGSize {
        arrangement(maxWidth: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews).containerSize
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Void
    ) {
        let arranged = arrangement(maxWidth: bounds.width, subviews: subviews)

        for index in subviews.indices {
            let origin = arranged.origins[index]
            let size = arranged.sizes[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private func arrangement(maxWidth: CGFloat, subviews: Subviews) -> (origins: [CGPoint], sizes: [CGSize], containerSize: CGSize) {
        let widthLimit = max(maxWidth, 1)
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > 0, x + size.width > widthLimit {
                maxRowWidth = max(maxRowWidth, rowWidth)
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
                rowWidth = 0
            }

            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)

            x += size.width + horizontalSpacing
            rowWidth = max(rowWidth, x - horizontalSpacing)
            rowHeight = max(rowHeight, size.height)
        }

        maxRowWidth = max(maxRowWidth, rowWidth)
        let totalHeight: CGFloat = subviews.isEmpty ? 0 : y + rowHeight
        return (origins, sizes, CGSize(width: maxRowWidth, height: totalHeight))
    }
}

extension Notification.Name {
    static let pushToTalkKeyChanged = Notification.Name("pushToTalkKeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
}

#Preview {
    GeneralSettingsView()
        .frame(width: 450, height: 500)
}
