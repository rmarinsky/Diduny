import AppKit
import SwiftUI

@MainActor
final class HistoryPaletteWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryPaletteWindowController()

    private var panel: NSPanel?
    private var eventMonitor: Any?

    private override init() {
        super.init()
    }

    func toggle() {
        if let panel, panel.isVisible {
            closeWindow()
        } else {
            showWindow()
        }
    }

    func showWindow() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HistoryPaletteView()
        let hostingView = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "History"
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false

        // Center on screen
        panel.center()

        panel.delegate = self
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Close on Escape key
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closeWindow()
                return nil
            }
            return event
        }
    }

    func closeWindow() {
        panel?.close()
        cleanupMonitor()
        panel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            cleanupMonitor()
            panel = nil
        }
    }

    private func cleanupMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
