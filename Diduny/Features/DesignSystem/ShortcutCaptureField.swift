import AppKit
import KeyboardShortcuts

/// Capture logic behind the Cancel and Translate-in-place keys fields (ADR-0012 D8). The visible
/// keycap is `ShortcutField` (WP-21); this view sits under it and records keys.
///
/// Only while capturing it installs a **local** monitor, so it sees keys of Diduny's own key window
/// and never another app's typing. It consumes key events and removes the monitor on commit, abort,
/// loss of key window, window close, or removal from the window.
@MainActor
final class ShortcutCaptureField: NSView {
    var mode: ShortcutCaptureMachine.Mode
    /// Chords of the other Diduny shortcuts, read when capture begins.
    var takenShortcuts: () -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut]
    var onCommit: ((ShortcutCaptureMachine.Captured) -> Void)?
    var onAbort: (() -> Void)?
    var onReject: ((ShortcutCaptureMachine.Rejection) -> Void)?
    var onCapturingChanged: ((Bool) -> Void)?

    private let session: ShortcutCaptureSession
    private var machine: ShortcutCaptureMachine
    private var monitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    var isCapturing: Bool {
        monitor != nil
    }

    init(
        mode: ShortcutCaptureMachine.Mode,
        session: ShortcutCaptureSession = .shared,
        takenShortcuts: @escaping () -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = { [:] }
    ) {
        self.mode = mode
        self.session = session
        self.takenShortcuts = takenShortcuts
        machine = ShortcutCaptureMachine(mode: mode)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with _: NSEvent) {
        beginCapture()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endCapture(abort: true) }
    }

    func beginCapture() {
        guard monitor == nil, let window else { return }
        machine = ShortcutCaptureMachine(mode: mode, takenShortcuts: takenShortcuts())
        session.begin()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseUp, .rightMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endCapture(abort: true) }
            })
        }
        onCapturingChanged?(true)
    }

    /// Ends capture without a value; the old value stays.
    func cancelCapture() {
        endCapture(abort: true)
    }

    /// Returns whether the event is consumed: key events are, mouse events are not.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseUp, .rightMouseUp:
            let inside = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
            if !inside { endCapture(abort: true) }
            return false
        default:
            guard let keyEvent = KeyEvent(event) else { return false }
            switch machine.handle(keyEvent) {
            case .pending:
                break
            case let .reject(reason):
                NSSound.beep()
                onReject?(reason)
            case let .commit(value):
                endCapture(abort: false)
                onCommit?(value)
            case .abort:
                endCapture(abort: true)
            }
            return true
        }
    }

    private func endCapture(abort: Bool) {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        session.end()
        onCapturingChanged?(false)
        if abort { onAbort?() }
    }
}
