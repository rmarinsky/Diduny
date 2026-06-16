import SwiftUI

@main
struct DidunyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                audioDeviceManager: appDelegate.audioDeviceManager,
                onToggleRecording: { appDelegate.toggleRecording() },
                onToggleTranslationRecording: { appDelegate.toggleTranslationRecording() },
                onToggleMeetingRecording: { appDelegate.toggleMeetingRecording() },
                onToggleMeetingTranslationRecording: { appDelegate.toggleMeetingTranslationRecording() },
                onTranscribeFile: { appDelegate.transcribeFile() },
                onOpenMainWindow: { section in appDelegate.openMainWindow(section: section) },
                onCheckForUpdates: { appDelegate.updaterManager.checkForUpdates() }
            )
            .environment(appDelegate.appState)
        } label: {
            MenuBarIconView()
                .environment(appDelegate.appState)
        }
        .menuBarExtraStyle(.menu)
    }
}
