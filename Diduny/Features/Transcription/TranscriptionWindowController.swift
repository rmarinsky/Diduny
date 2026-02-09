import AppKit
import SwiftUI

final class TranscriptionWindowController {
    static let shared = TranscriptionWindowController()

    private var window: NSWindow?
    private var windowDelegate: TranscriptionWindowDelegate?

    private init() {}

    func showWindow(store: LiveTranscriptStore) {
        // If window exists, update its content with the new store
        if let window {
            let view = LiveTranscriptView(store: store)
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = LiveTranscriptView(store: store)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Live Transcript"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 350, height: 300)
        window.isReleasedWhenClosed = false

        // Position bottom-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 520
            let y = screenFrame.minY + 20
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.windowDelegate = TranscriptionWindowDelegate { [weak self] in
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

private final class TranscriptionWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}
