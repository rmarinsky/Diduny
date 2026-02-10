import AppKit
import SwiftUI

@MainActor
final class RecordingsLibraryWindowController {
    static let shared = RecordingsLibraryWindowController()

    private var window: NSWindow?
    private var windowDelegate: RecordingsLibraryWindowDelegate?

    private init() {}

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = RecordingsLibraryView()
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Recordings"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 700, height: 400)
        window.isReleasedWhenClosed = false

        // Center on screen
        window.center()

        self.windowDelegate = RecordingsLibraryWindowDelegate { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
        }
        window.delegate = self.windowDelegate

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        window?.close()
        window = nil
        windowDelegate = nil
    }
}

// MARK: - Window Delegate

private final class RecordingsLibraryWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}
