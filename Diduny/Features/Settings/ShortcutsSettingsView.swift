import AppKit
import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    @State private var pushToTalkKey = SettingsStorage.shared.pushToTalkKey
    @State private var pushToTalkHoldEnabled = SettingsStorage.shared.pushToTalkHoldEnabled
    @State private var pushToTalkToggleEnabled = SettingsStorage.shared.pushToTalkToggleEnabled
    @State private var pushToTalkTapCount = SettingsStorage.shared.pushToTalkToggleTapCount
    @State private var pushToTalkHoldStartDelay = SettingsStorage.shared.pushToTalkHoldStartDelaySeconds
    @State private var translationPushToTalkKey = SettingsStorage.shared.translationPushToTalkKey
    @State private var translationPushToTalkHoldEnabled = SettingsStorage.shared.translationPushToTalkHoldEnabled
    @State private var translationPushToTalkToggleEnabled = SettingsStorage.shared.translationPushToTalkToggleEnabled
    @State private var translationPushToTalkTapCount = SettingsStorage.shared.translationPushToTalkToggleTapCount
    @State private var translationPushToTalkHoldStartDelay =
        SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds
    @State private var recordingHotkeyPressCount = SettingsStorage.shared.recordingHotkeyPressCount
    @State private var translationHotkeyPressCount = SettingsStorage.shared.translationHotkeyPressCount
    @State private var translateSelectedTextHotkeyPressCount = SettingsStorage.shared.translateSelectedTextHotkeyPressCount
    @State private var escapeCancelEnabled = SettingsStorage.shared.escapeCancelEnabled
    @State private var escapeCancelPressCount = SettingsStorage.shared.escapeCancelPressCount
    @State private var escapeCancelSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio

    private let hotkeyPressCountOptions = [1, 2, 3]
    private let toggleTapCountOptions = [2, 3]
    private let escapePressCountOptions = [2, 3]

    var body: some View {
        Form {
            Section("Action Hotkeys") {
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

                hotkeyRow(
                    title: "Translate Selected Text:",
                    shortcut: .translateSelectedText,
                    pressCount: $translateSelectedTextHotkeyPressCount,
                    store: { SettingsStorage.shared.translateSelectedTextHotkeyPressCount = $0 }
                )

                betaHotkeyRow(title: "Meeting:", shortcutLabel: "Beta")
                betaHotkeyRow(title: "Meeting Translation:", shortcutLabel: "Beta")
            }

            Section("Modifier Key Recording") {
                modifierKeyRow(
                    title: "Dictation:",
                    key: $pushToTalkKey,
                    holdEnabled: $pushToTalkHoldEnabled,
                    toggleEnabled: $pushToTalkToggleEnabled,
                    tapCount: $pushToTalkTapCount,
                    holdStartDelay: $pushToTalkHoldStartDelay,
                    keyStore: {
                        SettingsStorage.shared.pushToTalkKey = $0
                        NotificationCenter.default.post(name: .pushToTalkKeyChanged, object: $0)
                    },
                    holdEnabledStore: {
                        SettingsStorage.shared.pushToTalkHoldEnabled = $0
                        NotificationCenter.default.post(name: .pushToTalkModeChanged, object: nil)
                    },
                    toggleEnabledStore: {
                        SettingsStorage.shared.pushToTalkToggleEnabled = $0
                        NotificationCenter.default.post(name: .pushToTalkModeChanged, object: nil)
                    },
                    tapCountStore: {
                        SettingsStorage.shared.pushToTalkToggleTapCount = $0
                        NotificationCenter.default.post(name: .pushToTalkTapCountChanged, object: $0)
                    },
                    holdStartDelayStore: {
                        SettingsStorage.shared.pushToTalkHoldStartDelaySeconds = $0
                        NotificationCenter.default.post(name: .pushToTalkHoldStartDelayChanged, object: $0)
                    }
                )

                modifierKeyRow(
                    title: "Translation:",
                    key: $translationPushToTalkKey,
                    holdEnabled: $translationPushToTalkHoldEnabled,
                    toggleEnabled: $translationPushToTalkToggleEnabled,
                    tapCount: $translationPushToTalkTapCount,
                    holdStartDelay: $translationPushToTalkHoldStartDelay,
                    keyStore: {
                        SettingsStorage.shared.translationPushToTalkKey = $0
                        NotificationCenter.default.post(name: .translationPushToTalkKeyChanged, object: $0)
                    },
                    holdEnabledStore: {
                        SettingsStorage.shared.translationPushToTalkHoldEnabled = $0
                        NotificationCenter.default.post(name: .translationPushToTalkModeChanged, object: nil)
                    },
                    toggleEnabledStore: {
                        SettingsStorage.shared.translationPushToTalkToggleEnabled = $0
                        NotificationCenter.default.post(name: .translationPushToTalkModeChanged, object: nil)
                    },
                    tapCountStore: {
                        SettingsStorage.shared.translationPushToTalkToggleTapCount = $0
                        NotificationCenter.default.post(name: .translationPushToTalkTapCountChanged, object: $0)
                    },
                    holdStartDelayStore: {
                        SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds = $0
                        NotificationCenter.default.post(name: .translationPushToTalkHoldStartDelayChanged, object: $0)
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
    private func betaHotkeyRow(title: String, shortcutLabel: String) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .frame(width: 160, alignment: .leading)

            Text(shortcutLabel)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(.quaternaryLabelColor).opacity(0.14), in: Capsule())

            Spacer()

            Text("Available in Recordings while Meetings is in beta.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .opacity(0.65)
    }

    @ViewBuilder
    private func modifierKeyRow(
        title: String,
        key: Binding<PushToTalkKey>,
        holdEnabled: Binding<Bool>,
        toggleEnabled: Binding<Bool>,
        tapCount: Binding<Int>,
        holdStartDelay: Binding<TimeInterval>,
        keyStore: @escaping (PushToTalkKey) -> Void,
        holdEnabledStore: @escaping (Bool) -> Void,
        toggleEnabledStore: @escaping (Bool) -> Void,
        tapCountStore: @escaping (Int) -> Void,
        holdStartDelayStore: @escaping (TimeInterval) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            }

            HStack(alignment: .center, spacing: 12) {
                Spacer()
                    .frame(width: 160)

                Toggle("Hold to talk", isOn: holdEnabled)
                    .disabled(key.wrappedValue == .none)

                holdDelaySlider(
                    title: "Start after",
                    selection: holdStartDelay
                )
                .disabled(key.wrappedValue == .none || !holdEnabled.wrappedValue)
                .opacity(key.wrappedValue == .none || !holdEnabled.wrappedValue ? 0.45 : 1.0)
            }

            HStack(alignment: .center, spacing: 12) {
                Spacer()
                    .frame(width: 160)

                Toggle("Toggle mode", isOn: toggleEnabled)
                    .disabled(key.wrappedValue == .none)

                pressCountPicker(
                    title: "Toggle after",
                    selection: tapCount,
                    options: toggleTapCountOptions
                )
                .disabled(key.wrappedValue == .none || !toggleEnabled.wrappedValue)
                .opacity(key.wrappedValue == .none || !toggleEnabled.wrappedValue ? 0.45 : 1.0)
            }

            Text(modifierSummary(
                key: key.wrappedValue,
                holdEnabled: holdEnabled.wrappedValue,
                toggleEnabled: toggleEnabled.wrappedValue,
                tapCount: tapCount.wrappedValue,
                holdStartDelay: holdStartDelay.wrappedValue
            ))
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 160)
        }
        .onChange(of: key.wrappedValue) { _, newValue in
            keyStore(newValue)
        }
        .onChange(of: holdEnabled.wrappedValue) { _, newValue in
            holdEnabledStore(newValue)
        }
        .onChange(of: toggleEnabled.wrappedValue) { _, newValue in
            toggleEnabledStore(newValue)
        }
        .onChange(of: tapCount.wrappedValue) { _, newValue in
            tapCountStore(newValue)
        }
        .onChange(of: holdStartDelay.wrappedValue) { _, newValue in
            holdStartDelayStore(newValue)
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

    private func holdDelaySlider(title: String, selection: Binding<TimeInterval>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Slider(value: selection, in: 0.5...2.0, step: 0.1)
                    .accessibilityLabel("Start recording after hold duration")
                    .accessibilityValue(formattedHoldDelay(selection.wrappedValue))

                Text(formattedHoldDelay(selection.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .leading)
            }
        }
        .frame(width: 190, alignment: .leading)
    }

    private func formattedHoldDelay(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }

    private func modifierSummary(
        key: PushToTalkKey,
        holdEnabled: Bool,
        toggleEnabled: Bool,
        tapCount: Int,
        holdStartDelay: TimeInterval
    ) -> String {
        guard key != .none else {
            return "Choose a modifier key to enable hold-to-talk or multi-tap toggle."
        }
        switch (holdEnabled, toggleEnabled) {
        case (true, true):
            return "Hold starts after \(formattedHoldDelay(holdStartDelay)); \(tapCount)x quick presses toggles hands-free recording."
        case (true, false):
            return "Hold starts after \(formattedHoldDelay(holdStartDelay)). Shorter presses are ignored."
        case (false, true):
            return "\(tapCount)x quick presses toggles recording. Single presses are ignored."
        case (false, false):
            return "Modifier key is selected but inactive until at least one mode is enabled."
        }
    }
}

extension Notification.Name {
    static let pushToTalkKeyChanged = Notification.Name("pushToTalkKeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
    static let pushToTalkTapCountChanged = Notification.Name("pushToTalkTapCountChanged")
    static let translationPushToTalkTapCountChanged = Notification.Name("translationPushToTalkTapCountChanged")
    static let pushToTalkModeChanged = Notification.Name("pushToTalkModeChanged")
    static let translationPushToTalkModeChanged = Notification.Name("translationPushToTalkModeChanged")
    static let pushToTalkHoldStartDelayChanged = Notification.Name("pushToTalkHoldStartDelayChanged")
    static let translationPushToTalkHoldStartDelayChanged =
        Notification.Name("translationPushToTalkHoldStartDelayChanged")
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 640, height: 520)
}
