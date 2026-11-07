import AppKit
import KeyboardShortcuts
import SwiftUI

/// WP-15's `ShortcutCaptureField` laid over the styled `ShortcutField` for the two rows the package
/// recorder cannot take (ADR-0012 D8): Cancel (any key) and in place (modifier-only or key chord).
struct ShortcutCaptureOverlay: NSViewRepresentable {
    let mode: ShortcutCaptureMachine.Mode
    let takenShortcuts: () -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut]
    @Binding var isRecording: Bool
    let onCommit: (ShortcutCaptureMachine.Captured) -> Void

    func makeNSView(context _: Context) -> ShortcutCaptureField {
        let field = ShortcutCaptureField(mode: mode, takenShortcuts: takenShortcuts)
        configure(field)
        return field
    }

    func updateNSView(_ field: ShortcutCaptureField, context _: Context) {
        field.mode = mode
        field.takenShortcuts = takenShortcuts
        configure(field)
    }

    private func configure(_ field: ShortcutCaptureField) {
        let binding = $isRecording
        field.onCapturingChanged = { binding.wrappedValue = $0 }
        field.onCommit = onCommit
    }
}

/// Invisible `KeyboardShortcuts.RecorderCocoa` laid over the styled field (spec 4.14, D8). A click
/// anywhere on the field starts recording; the recorder's own Escape keeps the old value. The
/// visible layer, "Press keys..." and the accent border, is `ShortcutField` driven by `isRecording`.
///
/// The recorder fills the whole field: it cancels recording on a mouse-up outside its own bounds.
struct ShortcutRecorderOverlay: NSViewRepresentable {
    /// Posted with the shortcut name's raw value: the field's accessibility press starts recording.
    static let startRecordingNotification = Notification.Name("ShortcutRecorderOverlay.startRecording")

    let name: KeyboardShortcuts.Name
    @Binding var isRecording: Bool
    let onChange: () -> Void

    func makeNSView(context _: Context) -> Container {
        Container(name: name, onRecordingChange: { isRecording = $0 }, onChange: onChange)
    }

    func updateNSView(_ nsView: Container, context _: Context) {
        nsView.recorder.shortcutName = name
        nsView.wantsRecording = isRecording
    }

    final class Container: NSView {
        private(set) var recorder: KeyboardShortcuts.RecorderCocoa!
        private let onRecordingChange: (Bool) -> Void
        private var endEditingObserver: NSObjectProtocol?
        private var startObserver: NSObjectProtocol?
        /// SwiftUI detaches and re-attaches this host when the field redraws for `isRecording`; the
        /// detach resigns the recorder, which is not the user ending the recording.
        private var isDetaching = false

        /// The row's `isRecording`: the recorder holds focus while it is set, also across a re-attach.
        var wantsRecording = false {
            didSet { focusRecorderIfWanted() }
        }

        init(name: KeyboardShortcuts.Name, onRecordingChange: @escaping (Bool) -> Void, onChange: @escaping () -> Void) {
            self.onRecordingChange = onRecordingChange
            super.init(frame: .zero)
            recorder = KeyboardShortcuts.RecorderCocoa(for: name) { [weak self] _ in
                self?.onRecordingChange(false)
                onChange()
            }
            recorder.alphaValue = 0.01
            recorder.focusRingType = .none
            addSubview(recorder)
            endEditingObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidEndEditingNotification,
                object: recorder,
                queue: .main
            ) { [weak self] _ in
                #if TEST_BUILD
                    UITestCaptureTrace.note("endEditing detaching=\(self?.isDetaching ?? false)")
                #endif
                guard let self, !isDetaching else { return }
                onRecordingChange(false)
            }
            startObserver = NotificationCenter.default.addObserver(
                forName: ShortcutRecorderOverlay.startRecordingNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, note.object as? String == recorder.shortcutName.rawValue else { return }
                startRecording()
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit {
            if let endEditingObserver { NotificationCenter.default.removeObserver(endEditingObserver) }
            if let startObserver { NotificationCenter.default.removeObserver(startObserver) }
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func viewWillMove(toSuperview newSuperview: NSView?) {
            #if TEST_BUILD
                UITestCaptureTrace.note("willMoveSuperview nil=\(newSuperview == nil)")
            #endif
            if newSuperview == nil { isDetaching = true }
            super.viewWillMove(toSuperview: newSuperview)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            #if TEST_BUILD
                UITestCaptureTrace.note("willMoveWindow nil=\(newWindow == nil)")
            #endif
            if newWindow == nil { isDetaching = true }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            #if TEST_BUILD
                UITestCaptureTrace.note("didMoveWindow nil=\(window == nil) self=\(ObjectIdentifier(self).hashValue % 1000)")
            #endif
            guard window != nil else { return }
            isDetaching = false
            focusRecorderIfWanted()
        }

        private func focusRecorderIfWanted() {
            #if TEST_BUILD
                UITestCaptureTrace.note("focus? wants=\(wantsRecording) det=\(isDetaching) win=\(window != nil) ed=\(recorder.currentEditor() != nil)")
            #endif
            guard wantsRecording, !isDetaching, let window, recorder.currentEditor() == nil else { return }
            window.makeFirstResponder(recorder)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            !isHiddenOrHasHiddenAncestor && bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func mouseDown(with _: NSEvent) {
            #if TEST_BUILD
                UITestCaptureTrace.note("mouseDown")
            #endif
            startRecording()
        }

        private func startRecording() {
            onRecordingChange(true)
            let made = window?.makeFirstResponder(recorder) ?? false
            #if TEST_BUILD
                UITestCaptureTrace.note("start key=\(window?.isKeyWindow ?? false) made=\(made)")
            #else
                _ = made
            #endif
        }

        override func layout() {
            super.layout()
            recorder.frame = bounds
        }
    }
}
