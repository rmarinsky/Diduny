import AppKit
import SwiftUI

@MainActor
final class TypingTestWindowController: NSObject, NSWindowDelegate {
    static let shared = TypingTestWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func showWindow() {
        if let window {
            present(window)
            return
        }

        let view = TypingTestView { [weak self] in
            self?.closeWindow()
        }
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Typing Speed Test"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("diduny.typing-test")
        window.center()
        window.delegate = self

        self.window = window
        present(window)
    }

    func closeWindow() {
        window?.close()
        window = nil
        MainWindowController.shared.refreshActivationPolicy()
    }

    nonisolated func windowWillClose(_: Notification) {
        Task { @MainActor in
            window = nil
            MainWindowController.shared.refreshActivationPolicy()
        }
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
