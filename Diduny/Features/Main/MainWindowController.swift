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
    private weak var appDelegate: AppDelegate?

    var isVisible: Bool { window?.isVisible ?? false }

    private init() {}

    func configure(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func showWindow(section: MainSection? = nil) {
        if let section {
            requestedSection = section
        }

        Log.app.info("[Window] showWindow requested section=\(String(describing: section), privacy: .public)")

        presentWindow()

        // MenuBarExtra(.menu) actions run while AppKit is still tracking the
        // status-menu click. Retry shortly after the action unwinds so activation
        // and ordering are not lost to menu tracking.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard self?.isVisible != true else { return }
            self?.presentWindow()
        }
    }

    func closeWindow() {
        window?.close()
    }

    func refreshActivationPolicy() {
        appDelegate?.refreshActivationPolicy()
    }

    func toggleRecording() {
        appDelegate?.toggleRecording()
    }

    func toggleMeetingRecording() {
        appDelegate?.toggleMeetingRecording()
    }

    func checkForUpdates() {
        appDelegate?.updaterManager.checkForUpdates()
    }

    private func presentWindow() {
        if window == nil {
            makeWindow()
        }

        Log.app.info("[Window] presentWindow policy=\(NSApp.activationPolicy().rawValue, privacy: .public) window=\(self.window != nil, privacy: .public) visible=\((self.window?.isVisible ?? false), privacy: .public)")
        NSLog("[Diduny] showWindow: policy=%d window=%d visible=%d",
              NSApp.activationPolicy().rawValue, window != nil ? 1 : 0, window?.isVisible ?? false ? 1 : 0)

        // Promote to regular BEFORE makeKeyAndOrderFront so the window can
        // actually appear on screen. LSUIElement/.accessory apps cannot bring
        // windows to front without first switching activation policy.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
        window?.deminiaturize(nil)
        ensureWindowIsOnVisibleScreen()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSLog("[Diduny] showWindow: after show, visible=%d", window?.isVisible ?? false ? 1 : 0)
        // The .accessory → .regular switch settles asynchronously in the
        // process manager; without this retry the window can stay behind
        // other apps' windows on macOS 26.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            self?.window?.deminiaturize(nil)
            self?.ensureWindowIsOnVisibleScreen()
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    private func makeWindow() {
        guard let appDelegate else {
            Log.app.error("[Window] makeWindow failed: MainWindowController is not configured")
            return
        }

        let initialSection = requestedSection ?? .overview
        requestedSection = nil
        Log.app.info("[Window] makeWindow initialSection=\(initialSection.rawValue, privacy: .public)")

        let view = MainWindowView(initialSection: initialSection)
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
        configureUnifiedChrome(for: w)
        w.contentMinSize = NSSize(width: 900, height: 600)
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.setFrameAutosaveName("diduny.main")
        w.center()

        windowDelegate = MainWindowDelegate { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
            self?.refreshActivationPolicy()
        }
        w.delegate = windowDelegate

        window = w
    }

    private func configureUnifiedChrome(for window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.toolbar = nil
        DispatchQueue.main.async { [weak window] in
            window?.toolbar = nil
        }
    }

    private func ensureWindowIsOnVisibleScreen() {
        guard let window else { return }

        let isVisibleOnAnyScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(window.frame)
        }

        if !isVisibleOnAnyScreen {
            window.center()
        }
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
