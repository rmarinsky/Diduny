import SwiftUI
import Carbon

struct GeneralSettingsView: View {
    @State private var autoPaste = SettingsStorage.shared.autoPaste
    @State private var playSound = SettingsStorage.shared.playSoundOnCompletion
    @State private var showNotification = SettingsStorage.shared.showNotification
    @State private var launchAtLogin = SettingsStorage.shared.launchAtLogin
    @State private var isRecordingHotkey = false
    @State private var currentHotkey: KeyCombo? = SettingsStorage.shared.globalHotkey
    @State private var pushToTalkKey = SettingsStorage.shared.pushToTalkKey
    @State private var eventMonitor: Any?
    @State private var isRecordingTranslationHotkey = false
    @State private var translationHotkey: KeyCombo? = SettingsStorage.shared.translationHotkey
    @State private var translationEventMonitor: Any?
    @State private var translationPushToTalkKey = SettingsStorage.shared.translationPushToTalkKey

    var body: some View {
        Form {
            Section {
                hotkeySection
            } header: {
                Text("Global Hotkey")
            }

            Section {
                translationHotkeySection
            } header: {
                Text("Translation Hotkey")
            } footer: {
                Text("Translate between English and Ukrainian. Auto-detects the spoken language.")
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
            } header: {
                Text("Push to Talk")
            } footer: {
                Text("Hold the key to record, release to stop and transcribe.")
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

                Toggle("Show notification", isOn: $showNotification)
                    .onChange(of: showNotification) { _, newValue in
                        SettingsStorage.shared.showNotification = newValue
                    }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        SettingsStorage.shared.launchAtLogin = newValue
                        // TODO: Implement launch at login with SMAppService
                    }
            } header: {
                Text("Behavior")
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeySection: some View {
        HStack {
            Text("Start/Stop Recording:")

            Spacer()

            Button(action: {
                if isRecordingHotkey {
                    stopRecordingHotkey()
                } else {
                    startRecordingHotkey()
                }
            }) {
                Text(hotkeyDisplayString)
                    .frame(minWidth: 100)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecordingHotkey ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            if currentHotkey != nil {
                Button(action: clearHotkey) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear hotkey")
            }
        }
    }

    private var hotkeyDisplayString: String {
        if isRecordingHotkey {
            return "Press keys..."
        }
        return currentHotkey?.displayString ?? "Not set"
    }

    private func startRecordingHotkey() {
        isRecordingHotkey = true

        // Add local monitor for key events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if event.keyCode == 53 { // Escape - cancel
                stopRecordingHotkey()
                return nil
            }

            if let combo = KeyCombo.from(event: event) {
                currentHotkey = combo
                SettingsStorage.shared.globalHotkey = combo
                NotificationCenter.default.post(name: .hotkeyChanged, object: combo)
                stopRecordingHotkey()
                return nil // Consume the event
            }

            return event
        }
    }

    private func stopRecordingHotkey() {
        isRecordingHotkey = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func clearHotkey() {
        currentHotkey = nil
        SettingsStorage.shared.globalHotkey = nil
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }

    // MARK: - Translation Hotkey

    private var translationHotkeySection: some View {
        HStack {
            Text("Translate EN ↔ UK:")

            Spacer()

            Button(action: {
                if isRecordingTranslationHotkey {
                    stopRecordingTranslationHotkey()
                } else {
                    startRecordingTranslationHotkey()
                }
            }) {
                Text(translationHotkeyDisplayString)
                    .frame(minWidth: 100)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecordingTranslationHotkey ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            if translationHotkey != nil {
                Button(action: clearTranslationHotkey) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear translation hotkey")
            }
        }
    }

    private var translationHotkeyDisplayString: String {
        if isRecordingTranslationHotkey {
            return "Press keys..."
        }
        return translationHotkey?.displayString ?? "Not set"
    }

    private func startRecordingTranslationHotkey() {
        isRecordingTranslationHotkey = true

        translationEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if event.keyCode == 53 { // Escape - cancel
                stopRecordingTranslationHotkey()
                return nil
            }

            if let combo = KeyCombo.from(event: event) {
                translationHotkey = combo
                SettingsStorage.shared.translationHotkey = combo
                NotificationCenter.default.post(name: .translationHotkeyChanged, object: combo)
                stopRecordingTranslationHotkey()
                return nil
            }

            return event
        }
    }

    private func stopRecordingTranslationHotkey() {
        isRecordingTranslationHotkey = false
        if let monitor = translationEventMonitor {
            NSEvent.removeMonitor(monitor)
            translationEventMonitor = nil
        }
    }

    private func clearTranslationHotkey() {
        translationHotkey = nil
        SettingsStorage.shared.translationHotkey = nil
        NotificationCenter.default.post(name: .translationHotkeyChanged, object: nil)
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
    static let hotkeyChanged = Notification.Name("hotkeyChanged")
    static let translationHotkeyChanged = Notification.Name("translationHotkeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
}

#Preview {
    GeneralSettingsView()
        .frame(width: 450, height: 300)
}
