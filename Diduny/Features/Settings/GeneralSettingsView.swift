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
                Text("Uses the same recording mode as Push to Talk above.")
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

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.isEnabled = newValue
                    }
            } header: {
                Text("Behavior")
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recording:")
                    .frame(width: 100, alignment: .leading)
                KeyboardShortcuts.Recorder(for: .toggleRecording)
            }

            HStack {
                Text("Translation:")
                    .frame(width: 100, alignment: .leading)
                KeyboardShortcuts.Recorder(for: .toggleTranslation)
            }

            HStack {
                Text("Meeting:")
                    .frame(width: 100, alignment: .leading)
                KeyboardShortcuts.Recorder(for: .toggleMeetingRecording)
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

extension Notification.Name {
    static let pushToTalkKeyChanged = Notification.Name("pushToTalkKeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
}

#Preview {
    GeneralSettingsView()
        .frame(width: 450, height: 500)
}
