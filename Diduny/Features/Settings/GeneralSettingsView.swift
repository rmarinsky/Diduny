import AppKit
import LaunchAtLogin
import SwiftUI

struct GeneralSettingsView: View {
    @State private var autoPaste = SettingsStorage.shared.autoPaste
    @State private var playSound = SettingsStorage.shared.playSoundOnCompletion
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var escapeCancelEnabled = SettingsStorage.shared.escapeCancelEnabled
    @State private var escapeCancelShortcut = SettingsStorage.shared.escapeCancelShortcut
    @State private var escapeCancelSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
    @State private var isRecordingEscapeCancelShortcut = false
    @State private var escapeCancelShortcutMonitor: Any?

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
        }
        .onDisappear {
            stopEscapeCancelShortcutCapture()
        }
    }

    // MARK: - Helpers

    private func showOnboarding() {
        OnboardingManager.shared.showFromSettings()
        OnboardingWindowController.shared.showOnboarding {
            // Onboarding completed
        }
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
}

#Preview {
    GeneralSettingsView()
        .frame(width: 500, height: 400)
}
