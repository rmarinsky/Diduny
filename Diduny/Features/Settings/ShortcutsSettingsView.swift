import AppKit
import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    @State private var pushToTalkKey = SettingsStorage.shared.pushToTalkKey
    @State private var translationPushToTalkKey = SettingsStorage.shared.translationPushToTalkKey
    @State private var handsFreeModeEnabled = SettingsStorage.shared.handsFreeModeEnabled

    var body: some View {
        Form {
            Section("Global Hotkeys") {
                hotkeySection
            }

            Section("Recording Mode") {
                Picker("Mode:", selection: $handsFreeModeEnabled) {
                    Text("Hold to record").tag(false)
                    Text("Toggle (double-tap)").tag(true)
                }
                .onChange(of: handsFreeModeEnabled) { _, newValue in
                    SettingsStorage.shared.handsFreeModeEnabled = newValue
                }

                Text(handsFreeModeEnabled
                    ? "Double-tap the key to start recording, double-tap again to stop."
                    : "Hold the key down while speaking, release to transcribe.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Shortcut Keys") {
                Picker("Dictation:", selection: $pushToTalkKey) {
                    ForEach(PushToTalkKey.allCases) { key in
                        Text(key.pickerLabel).tag(key)
                    }
                }
                .onChange(of: pushToTalkKey) { _, newValue in
                    SettingsStorage.shared.pushToTalkKey = newValue
                    NotificationCenter.default.post(name: .pushToTalkKeyChanged, object: newValue)
                }

                Picker("Translation:", selection: $translationPushToTalkKey) {
                    ForEach(PushToTalkKey.allCases) { key in
                        Text(key.pickerLabel).tag(key)
                    }
                }
                .onChange(of: translationPushToTalkKey) { _, newValue in
                    SettingsStorage.shared.translationPushToTalkKey = newValue
                    NotificationCenter.default.post(name: .translationPushToTalkKeyChanged, object: newValue)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Hotkey Section

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
                Text("Double-press \u{2318}C")
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

}

extension Notification.Name {
    static let pushToTalkKeyChanged = Notification.Name("pushToTalkKeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 500, height: 500)
}
