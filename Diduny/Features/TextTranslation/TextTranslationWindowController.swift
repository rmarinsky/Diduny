import AppKit
import SwiftUI

@MainActor
final class TextTranslationWindowController: NSObject, NSWindowDelegate {
    static let shared = TextTranslationWindowController()

    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var viewModel: TextTranslationViewModel?

    private override init() {
        super.init()
    }

    func showWindow(sourceText: String) {
        // If window exists, update the view model and bring to front
        if let panel, panel.isVisible, let viewModel {
            viewModel.sourceText = sourceText
            viewModel.translatedText = ""
            viewModel.errorMessage = nil
            viewModel.showCopiedConfirmation = false
            viewModel.updateDetectedLanguage()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        closeWindow()

        let vm = TextTranslationViewModel(sourceText: sourceText)
        viewModel = vm

        let view = TextTranslationView(viewModel: vm) { [weak self] in
            self?.closeWindow()
        }
        let hostingView = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "Translate"
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false

        panel.center()

        panel.delegate = self
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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
        viewModel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            cleanupMonitor()
            panel = nil
            viewModel = nil
        }
    }

    private func cleanupMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
