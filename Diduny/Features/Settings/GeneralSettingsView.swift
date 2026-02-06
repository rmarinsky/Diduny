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
                translationPushToTalkSection
            } header: {
                Text("Translation Push to Talk")
            } footer: {
                Text("Hold the key to record, release to translate (EN ↔ UK).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                pushToTalkSection

                Divider()
                    .padding(.vertical, 4)

                Toggle("Enable hands-free mode", isOn: $handsFreeModeEnabled)
                    .onChange(of: handsFreeModeEnabled) { _, newValue in
                        SettingsStorage.shared.handsFreeModeEnabled = newValue
                    }

                if handsFreeModeEnabled {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brief tap: toggle recording on/off")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Long press (>0.5s): hold to record")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 20)
                }
            } header: {
                Text("Push to Talk")
            } footer: {
                if !handsFreeModeEnabled {
                    Text("Hold the key to record, release to stop and transcribe.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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

    // MARK: - Translation Push to Talk

    private var translationPushToTalkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                HStack {
                    Image(systemName: translationPushToTalkKey == key ? "circle.inset.filled" : "circle")
                        .foregroundColor(translationPushToTalkKey == key ? .accentColor : .secondary)

                    Text(key.displayName)

                    if !key.symbol.isEmpty {
                        Text(key.symbol)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    translationPushToTalkKey = key
                    SettingsStorage.shared.translationPushToTalkKey = key
                    NotificationCenter.default.post(name: .translationPushToTalkKeyChanged, object: key)
                }
            }
        }
    }

    private var pushToTalkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                HStack {
                    Image(systemName: pushToTalkKey == key ? "circle.inset.filled" : "circle")
                        .foregroundColor(pushToTalkKey == key ? .accentColor : .secondary)

                    Text(key.displayName)

                    if !key.symbol.isEmpty {
                        Text(key.symbol)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    pushToTalkKey = key
                    SettingsStorage.shared.pushToTalkKey = key
                    NotificationCenter.default.post(name: .pushToTalkKeyChanged, object: key)
                }
            }
        }
    }
}

extension Notification.Name {
    static let pushToTalkKeyChanged = Notification.Name("pushToTalkKeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
}

#Preview {
    GeneralSettingsView()
        .frame(width: 450, height: 400)
}
