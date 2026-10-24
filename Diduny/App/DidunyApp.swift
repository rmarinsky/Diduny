import SwiftUI

@main
struct DidunyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar item is an NSStatusItem (StatusMenuController) so its menu can host
        // SwiftUI rows. This scene only carries the app commands; Settings opens Diduny's window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openMainWindow(section: .general) }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .newItem) {
                    Button(MainWindowController.batchComposerActionTitle) {
                        appDelegate.batchFilesAndURLs()
                    }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                }
            }
    }
}
