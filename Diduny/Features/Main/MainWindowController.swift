import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    var requestedSection: MainSection? = nil

    private var window: NSWindow?
    private var windowDelegate: MainWindowDelegate?

    var isVisible: Bool { window?.isVisible ?? false }

    private init() {}

    func showWindow(section: MainSection? = nil) {
        if let section {
            requestedSection = section
        }

        if window == nil {
            makeWindow()
        }

        window?.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closeWindow() {
        window?.close()
    }

    private func makeWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        let view = MainWindowView()
            .environment(appDelegate.appState)
            .environment(appDelegate.audioDeviceManager)

        let hostingView = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Diduny"
        w.contentView = hostingView
        w.contentMinSize = NSSize(width: 900, height: 600)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("diduny.main")
        w.center()

        windowDelegate = MainWindowDelegate { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.refreshActivationPolicy()
            }
        }
        w.delegate = windowDelegate

        window = w
    }
}

private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}
