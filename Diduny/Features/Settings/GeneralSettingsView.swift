import LaunchAtLogin
import SwiftUI

struct GeneralSettingsView: View {
    @State private var autoPaste = SettingsStorage.shared.autoPaste
    @State private var playSound = SettingsStorage.shared.playSoundOnCompletion
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var screenRecordingPromptEnabled = !SettingsStorage.shared.userDeclinedScreenRecording

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

            } header: {
                Text("Behavior")
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
                        (NSApp.delegate as? AppDelegate)?.updaterManager.checkForUpdates()
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
            screenRecordingPromptEnabled = !SettingsStorage.shared.userDeclinedScreenRecording
        }
    }

    // MARK: - Helpers

    private func showOnboarding() {
        OnboardingManager.shared.showFromSettings()
        OnboardingWindowController.shared.showOnboarding {
            // Onboarding completed from settings
        }
    }

}

#Preview {
    GeneralSettingsView()
        .frame(width: 500, height: 400)
}
