import SwiftUI

@main
struct DidunyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        // Use MenuBarExtra for menu bar presence (macOS 13+)
        MenuBarExtra {
            MenuBarContentView(
                audioDeviceManager: appDelegate.audioDeviceManager,
                onToggleRecording: { appDelegate.toggleRecording() },
                onToggleTranslationRecording: { appDelegate.toggleTranslationRecording() },
                onToggleMeetingRecording: { appDelegate.toggleMeetingRecording() },
                onToggleMeetingTranslationRecording: { appDelegate.toggleMeetingTranslationRecording() },
                onTranscribeFile: { appDelegate.transcribeFile() },
                onCheckForUpdates: { appDelegate.updaterManager.checkForUpdates() }
            )
            .environment(appDelegate.appState)
            .onChange(of: appDelegate.appState.shouldOpenSettings) { _, shouldOpen in
                if shouldOpen {
                    openSettings()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    appDelegate.appState.shouldOpenSettings = false
                }
            }
            .onChange(of: appDelegate.appState.settingsTabToOpen) { _, tab in
                if tab != nil {
                    openSettings()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        } label: {
            MenuBarIconView()
                .environment(appDelegate.appState)
        }
        .menuBarExtraStyle(.menu)

        // SwiftUI-managed Settings window
        Settings {
            SettingsView()
                .environment(appDelegate.appState)
                .environment(appDelegate.audioDeviceManager)
        }
    }
}
