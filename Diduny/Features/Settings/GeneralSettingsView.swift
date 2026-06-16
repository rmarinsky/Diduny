import LaunchAtLogin
import SwiftUI

struct GeneralSettingsView: View {
    @State private var autoPaste = SettingsStorage.shared.autoPaste
    @State private var playSound = SettingsStorage.shared.playSoundOnCompletion
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var recordingFeedbackSurface = SettingsStorage.shared.recordingFeedbackSurface
    @State private var typingSpeedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
    @State private var screenRecordingPromptEnabled = !SettingsStorage.shared.userDeclinedScreenRecording
    @State private var dictationRetention = SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy
    @State private var meetingRetention = SettingsStorage.shared.meetingHistoryRetentionPolicy

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        Form {
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

                Picker("Recording feedback", selection: $recordingFeedbackSurface) {
                    ForEach(RecordingFeedbackSurface.allCases) { surface in
                        Text(surface.displayName).tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: recordingFeedbackSurface) { _, newValue in
                    SettingsStorage.shared.recordingFeedbackSurface = newValue
                }

            } header: {
                Text("Behavior")
            }

            Section {
                HStack {
                    Text("Typing speed")
                    Spacer()
                    Text("\(formatWordsPerMinute(typingSpeedWordsPerMinute)) WPM")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                Button("Run Typing Speed Test…") {
                    TypingTestWindowController.shared.showWindow()
                }
                .buttonStyle(.link)
            } header: {
                Text("Statistics")
            } footer: {
                Text("Used to estimate typing time avoided in Overview.")
            }

            Section {
                Picker("Dictation & translation", selection: $dictationRetention) {
                    ForEach(HistoryRetentionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .onChange(of: dictationRetention) { _, newValue in
                    SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = newValue
                    pruneExpiredHistoryIfNeeded()
                }

                Picker("Meeting recordings (beta)", selection: $meetingRetention) {
                    ForEach(HistoryRetentionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .onChange(of: meetingRetention) { _, newValue in
                    SettingsStorage.shared.meetingHistoryRetentionPolicy = newValue
                    pruneExpiredHistoryIfNeeded()
                }

                Button("Delete Expired History Now") {
                    RecordingsLibraryStorage.shared.pruneExpiredRecordings()
                }
                .buttonStyle(.link)
            } header: {
                Text("History & Storage")
            } footer: {
                Text("Choose how long Diduny keeps recordings in the library. Meeting recordings remain available under Recordings while Meetings is in beta.")
            }

            Section {
                // Toggling ON clears the declined flag so next launch can prompt again.
                Toggle("Re-enable Screen Recording prompt", isOn: $screenRecordingPromptEnabled)
                    .onChange(of: screenRecordingPromptEnabled) { _, newValue in
                        SettingsStorage.shared.userDeclinedScreenRecording = !newValue
                    }
            } header: {
                Text("Onboarding")
            } footer: {
                Text("When enabled, Diduny will prompt you to grant Screen Recording permission on next launch if it is not yet granted.")
            }

            Section {
                Button("Show Welcome Tour") {
                    showOnboarding()
                }
                .buttonStyle(.link)
            } header: {
                Text("Help")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diduny")
                            .font(.headline)
                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates…") {
                        MainWindowController.shared.checkForUpdates()
                    }
                    .buttonStyle(.link)
                }

                Link(destination: URL(string: "https://rmarinsky.com.ua")!) {
                    HStack {
                        Text("Website")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Made in Ukraine · © 2024–2026 Roman Marinsky")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            recordingFeedbackSurface = SettingsStorage.shared.recordingFeedbackSurface
            typingSpeedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
            screenRecordingPromptEnabled = !SettingsStorage.shared.userDeclinedScreenRecording
            dictationRetention = SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy
            meetingRetention = SettingsStorage.shared.meetingHistoryRetentionPolicy
        }
        .onReceive(NotificationCenter.default.publisher(for: .typingSpeedSettingsChanged)) { _ in
            typingSpeedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
        }
    }

    // MARK: - Helpers

    private func showOnboarding() {
        OnboardingManager.shared.showFromSettings()
        OnboardingWindowController.shared.showOnboarding {
            // Onboarding completed from settings
        }
    }

    private func pruneExpiredHistoryIfNeeded() {
        RecordingsLibraryStorage.shared.pruneExpiredRecordings()
    }

    private func formatWordsPerMinute(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 500, height: 400)
}
