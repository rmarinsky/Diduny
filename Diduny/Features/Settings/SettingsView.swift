import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "mic")
                }

            MeetingSettingsView()
                .tabItem {
                    Label("Meetings", systemImage: "person.3")
                }

            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }

            TranscriptionSettingsView()
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 600, height: 650)
        .onAppear {
            // Show app in Dock and Cmd+Tab when Settings is open
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            // Hide from Dock and Cmd+Tab when Settings is closed
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
