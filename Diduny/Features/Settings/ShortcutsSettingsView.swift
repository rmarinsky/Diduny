import AppKit
import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    @State private var pushToTalkKey = SettingsStorage.shared.pushToTalkKey
    @State private var pushToTalkTapCount = SettingsStorage.shared.pushToTalkToggleTapCount
    @State private var translationPushToTalkKey = SettingsStorage.shared.translationPushToTalkKey
    @State private var translationPushToTalkTapCount = SettingsStorage.shared.translationPushToTalkToggleTapCount
    @State private var handsFreeModeEnabled = SettingsStorage.shared.handsFreeModeEnabled
    @State private var recordingHotkeyPressCount = SettingsStorage.shared.recordingHotkeyPressCount
    @State private var translationHotkeyPressCount = SettingsStorage.shared.translationHotkeyPressCount
    @State private var meetingHotkeyPressCount = SettingsStorage.shared.meetingHotkeyPressCount
    @State private var meetingTranslationHotkeyPressCount = SettingsStorage.shared.meetingTranslationHotkeyPressCount
    @State private var escapeCancelEnabled = SettingsStorage.shared.escapeCancelEnabled
    @State private var escapeCancelPressCount = SettingsStorage.shared.escapeCancelPressCount
    @State private var escapeCancelSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio

    private let hotkeyPressCountOptions = [1, 2, 3]
    private let toggleTapCountOptions = [2, 3]
    private let escapePressCountOptions = [2, 3]

    var body: some View {
        Form {
            Section("Global Hotkeys") {
                hotkeyRow(
                    title: "Dictation:",
                    shortcut: .toggleRecording,
                    pressCount: $recordingHotkeyPressCount,
                    store: { SettingsStorage.shared.recordingHotkeyPressCount = $0 }
                )

                hotkeyRow(
                    title: "Translation:",
                    shortcut: .toggleTranslation,
                    pressCount: $translationHotkeyPressCount,
                    store: { SettingsStorage.shared.translationHotkeyPressCount = $0 }
                )

                HStack {
                    Text("Translate Selected Text:")
                        .frame(width: 160, alignment: .leading)
                    Text("Double-press \u{2318}C")
                        .foregroundColor(.secondary)
                }

                hotkeyRow(
                    title: "Meeting:",
                    shortcut: .toggleMeetingRecording,
                    pressCount: $meetingHotkeyPressCount,
                    store: { SettingsStorage.shared.meetingHotkeyPressCount = $0 }
                )

                hotkeyRow(
                    title: "Meeting Translation:",
                    shortcut: .toggleMeetingTranslation,
                    pressCount: $meetingTranslationHotkeyPressCount,
                    store: { SettingsStorage.shared.meetingTranslationHotkeyPressCount = $0 }
                )
            }

            Section("Modifier Keys") {
                Picker("Mode:", selection: $handsFreeModeEnabled) {
                    Text("Hold to record").tag(false)
                    Text("Toggle").tag(true)
                }
                .onChange(of: handsFreeModeEnabled) { _, newValue in
                    SettingsStorage.shared.handsFreeModeEnabled = newValue
                }

                Text(
                    handsFreeModeEnabled
                        ? "Use the selected tap count to start and stop recording from the modifier key."
                        : "Hold the key down while speaking, release to transcribe."
                )
                .font(.caption)
                .foregroundColor(.secondary)

                modifierKeyRow(
                    title: "Dictation:",
                    key: $pushToTalkKey,
                    tapCount: $pushToTalkTapCount,
                    keyStore: {
                        SettingsStorage.shared.pushToTalkKey = $0
                        NotificationCenter.default.post(name: .pushToTalkKeyChanged, object: $0)
                    },
                    tapCountStore: {
                        SettingsStorage.shared.pushToTalkToggleTapCount = $0
                        NotificationCenter.default.post(name: .pushToTalkTapCountChanged, object: $0)
                    }
                )

                modifierKeyRow(
                    title: "Translation:",
                    key: $translationPushToTalkKey,
                    tapCount: $translationPushToTalkTapCount,
                    keyStore: {
                        SettingsStorage.shared.translationPushToTalkKey = $0
                        NotificationCenter.default.post(name: .translationPushToTalkKeyChanged, object: $0)
                    },
                    tapCountStore: {
                        SettingsStorage.shared.translationPushToTalkToggleTapCount = $0
                        NotificationCenter.default.post(name: .translationPushToTalkTapCountChanged, object: $0)
                    }
                )
            }

            Section("Cancel Recording") {
                HStack(alignment: .center) {
                    Text("Shortcut:")
                        .frame(width: 160, alignment: .leading)

                Picker("Cancel Shortcut", selection: $escapeCancelEnabled) {
                    Text("None").tag(false)
                    Text("Esc").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)

                    Spacer(minLength: 12)

                    pressCountPicker(
                        title: "Cancel after",
                        selection: $escapeCancelPressCount,
                        options: escapePressCountOptions
                    )
                    .disabled(!escapeCancelEnabled)
                    .opacity(escapeCancelEnabled ? 1.0 : 0.45)
                }
                .onChange(of: escapeCancelEnabled) { _, newValue in
                    SettingsStorage.shared.escapeCancelEnabled = newValue
                    if !newValue {
                        EscapeCancelService.shared.deactivate()
                    }
                }
                .onChange(of: escapeCancelPressCount) { _, newValue in
                    SettingsStorage.shared.escapeCancelPressCount = newValue
                }

                Toggle("Save audio when cancelled", isOn: $escapeCancelSaveAudio)
                    .disabled(!escapeCancelEnabled)
                    .opacity(escapeCancelEnabled ? 1.0 : 0.45)
                    .onChange(of: escapeCancelSaveAudio) { _, newValue in
                        SettingsStorage.shared.escapeCancelSaveAudio = newValue
                    }

                Text(
                    escapeCancelEnabled
                        ? "Press Esc \(escapeCancelPressCount)x during recording to cancel."
                        : "Disable Escape cancellation completely."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Rows

    @ViewBuilder
    private func hotkeyRow(
        title: String,
        shortcut: KeyboardShortcuts.Name,
        pressCount: Binding<Int>,
        store: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title)
                    .frame(width: 160, alignment: .leading)
                KeyboardShortcuts.Recorder(for: shortcut)
                Spacer(minLength: 12)
                pressCountPicker(
                    title: "Trigger after",
                    selection: pressCount,
                    options: hotkeyPressCountOptions
                )
            }

            Text("Trigger this shortcut after \(pressCount.wrappedValue)x press\(pressCount.wrappedValue == 1 ? "" : "es").")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 160)
        }
        .onChange(of: pressCount.wrappedValue) { _, newValue in
            store(newValue)
        }
    }

    @ViewBuilder
    private func modifierKeyRow(
        title: String,
        key: Binding<PushToTalkKey>,
        tapCount: Binding<Int>,
        keyStore: @escaping (PushToTalkKey) -> Void,
        tapCountStore: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title)
                    .frame(width: 160, alignment: .leading)

                Picker(title, selection: key) {
                    ForEach(PushToTalkKey.allCases) { option in
                        Text(option.pickerLabel).tag(option)
                    }
                }
                .labelsHidden()

                Spacer(minLength: 12)

                pressCountPicker(
                    title: "Toggle after",
                    selection: tapCount,
                    options: toggleTapCountOptions
                )
                    .disabled(!handsFreeModeEnabled)
                    .opacity(handsFreeModeEnabled ? 1.0 : 0.45)
            }

            Text(
                handsFreeModeEnabled
                    ? "Use \(tapCount.wrappedValue)x press\(tapCount.wrappedValue == 1 ? "" : "es") on the selected key to toggle."
                    : "Tap count applies only in Toggle mode."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 160)
        }
        .onChange(of: key.wrappedValue) { _, newValue in
            keyStore(newValue)
        }
        .onChange(of: tapCount.wrappedValue) { _, newValue in
            tapCountStore(newValue)
        }
    }

    private func pressCountPicker(title: String, selection: Binding<Int>, options: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { count in
                    Text("\(count)x").tag(count)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .frame(width: 150, alignment: .leading)
    }
}

extension Notification.Name {
    static let pushToTalkKeyChanged = Notification.Name("pushToTalkKeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
    static let pushToTalkTapCountChanged = Notification.Name("pushToTalkTapCountChanged")
    static let translationPushToTalkTapCountChanged = Notification.Name("translationPushToTalkTapCountChanged")
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 640, height: 520)
}
