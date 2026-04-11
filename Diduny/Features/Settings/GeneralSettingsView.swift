import LaunchAtLogin
import SwiftUI

struct GeneralSettingsView: View {
    @State private var autoPaste = SettingsStorage.shared.autoPaste
    @State private var playSound = SettingsStorage.shared.playSoundOnCompletion
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

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
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    // MARK: - Helpers

    private func showOnboarding() {
        OnboardingManager.shared.showFromSettings()
        OnboardingWindowController.shared.showOnboarding {
            // Onboarding completed
        }
    }

}

#Preview {
    GeneralSettingsView()
        .frame(width: 500, height: 400)
}
