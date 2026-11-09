import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()
    static let batchComposerActionTitle = String(localized: "Batch Files and URLs…")

    var requestedSection: MainSection?
    var requestedRecordingID: UUID?
    var requestedBatchComposer = false
    /// Modes opens with this expander open (Calendar & meetings link, WP-51).
    var requestedModesExpander: STTJob?

    private var window: NSWindow?
    private var windowDelegate: MainWindowDelegate?
    private weak var appDelegate: AppDelegate?

    var isVisible: Bool {
        window?.isVisible ?? false
    }

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

    func showRecording(id: UUID) {
        requestedRecordingID = id
        showWindow(section: .recordings)
    }

    func requestBatchComposer() {
        requestedBatchComposer = true
        requestedSection = .recordings
    }

    func closeWindow() {
        window?.performClose(nil)
    }

    func refreshActivationPolicy() {
        appDelegate?.refreshActivationPolicy()
    }

    func toggleRecording() {
        appDelegate?.toggleRecording()
    }

    static let defaultContentSize = NSSize(width: 1000, height: 680)
    static let recordingInspectorWidth: CGFloat = 480
    static let frameAutosaveName = "DidunyMainWindow"

    /// How much the inspector grew the window; nil when it did not grow it.
    private var inspectorGrowth: CGFloat?

    /// Opening the inspector grows the window only when the user's size leaves no room for it, and never
    /// past the screen; closing it gives back exactly what it took.
    func setRecordingInspectorExpanded(_ expanded: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let contentWidth = window.contentRect(forFrameRect: window.frame).width
        let targetContentWidth: CGFloat
        if expanded {
            guard inspectorGrowth == nil else { return }
            let needed = Self.defaultContentSize.width + Self.recordingInspectorWidth
            guard contentWidth < needed else { return }
            inspectorGrowth = needed - contentWidth
            targetContentWidth = needed
        } else {
            guard let growth = inspectorGrowth else { return }
            inspectorGrowth = nil
            targetContentWidth = max(Self.defaultContentSize.width, contentWidth - growth)
        }
        let delta = targetContentWidth - contentWidth
        var frame = window.frame
        frame.size.width += delta
        if let visible = window.screen?.visibleFrame {
            frame = Self.clamp(frame, to: visible)
        }
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    /// Fits a frame inside the visible screen: no larger than it, moved left/down to stay on it.
    static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    func checkForUpdates() {
        appDelegate?.updaterManager.checkForUpdates()
    }

    var canCheckForUpdates: Bool {
        appDelegate?.updaterManager.canCheckForUpdates ?? false
    }

    private func presentWindow() {
        if window == nil {
            makeWindow()
        }

        let windowExists = window != nil
        let windowVisible = window?.isVisible ?? false
        Log.app
            .info(
                "[Window] presentWindow policy=\(NSApp.activationPolicy().rawValue, privacy: .public) window=\(windowExists, privacy: .public) visible=\(windowVisible, privacy: .public)"
            )
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
        // The user owns the size; SwiftUI only sets the minimum. Without this the hosting view snaps
        // the window back to its intrinsic width.
        hostingView.sizingOptions = [.minSize]

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Diduny"
        w.contentView = hostingView
        configureUnifiedChrome(for: w)
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.contentMinSize = Self.defaultContentSize
        w.center()
        // Restores the size the user last set (first open keeps the 1000 x 680 default), then fits it on screen.
        w.setFrameAutosaveName(Self.frameAutosaveName)
        if let visible = (w.screen ?? NSScreen.main)?.visibleFrame {
            w.setFrame(Self.clamp(w.frame, to: visible), display: false)
        }

        windowDelegate = MainWindowDelegate { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
            self?.inspectorGrowth = nil
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

@MainActor
private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        RecordingTrimNavigation.shared.requestLeave()
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}
