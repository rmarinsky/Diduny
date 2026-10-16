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
                onBatchFilesAndURLs: { appDelegate.batchFilesAndURLs() },
                onOpenMainWindow: { section in appDelegate.openMainWindow(section: section) },
                onCheckForUpdates: { appDelegate.updaterManager.checkForUpdates() }
            )
            .environment(appDelegate.appState)
        } label: {
            HStack(spacing: 5) {
                MenuBarIconView().environment(appDelegate.appState)
                CalendarMenuLabel()
            }
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .newItem) {
                Button(MainWindowController.batchComposerActionTitle) {
                    appDelegate.batchFilesAndURLs()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
    }
}
