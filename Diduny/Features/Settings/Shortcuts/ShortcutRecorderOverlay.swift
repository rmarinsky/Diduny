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
///
/// The overlay, not the styled field under it, is the accessibility element: it is what a click
/// reaches, so the field is hittable, and VoiceOver can press it to start recording.
struct ShortcutRecorderOverlay: NSViewRepresentable {
    /// What the styled field would say: identifier, "<row> shortcut", the spoken keys.
    struct Accessibility: Equatable {
        var identifier: String
        var label: String
        var value: String
        var isEnabled: Bool
    }

    let name: KeyboardShortcuts.Name
    @Binding var isRecording: Bool
    let accessibility: Accessibility
    let onChange: () -> Void

    func makeNSView(context _: Context) -> Container {
        Container(name: name, onRecordingChange: { isRecording = $0 }, onChange: onChange)
    }

    func updateNSView(_ nsView: Container, context _: Context) {
        nsView.recorder.shortcutName = name
        nsView.accessibility = accessibility
    }

    final class Container: NSView {
        private(set) var recorder: KeyboardShortcuts.RecorderCocoa!
        private let onRecordingChange: (Bool) -> Void
        private var endEditingObserver: NSObjectProtocol?
        var accessibility = Accessibility(identifier: "", label: "", value: "", isEnabled: true)

        init(name: KeyboardShortcuts.Name, onRecordingChange: @escaping (Bool) -> Void, onChange: @escaping () -> Void) {
            self.onRecordingChange = onRecordingChange
            super.init(frame: .zero)
            recorder = KeyboardShortcuts.RecorderCocoa(for: name) { [weak self] _ in
                self?.onRecordingChange(false)
                onChange()
            }
            recorder.alphaValue = 0.01
            recorder.focusRingType = .none
            recorder.setAccessibilityElement(false)
            addSubview(recorder)
            endEditingObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidEndEditingNotification,
                object: recorder,
                queue: .main
            ) { [weak self] _ in
                self?.onRecordingChange(false)
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit {
            if let endEditingObserver { NotificationCenter.default.removeObserver(endEditingObserver) }
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            !isHiddenOrHasHiddenAncestor && bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func mouseDown(with _: NSEvent) {
            startRecording()
        }

        private func startRecording() {
            onRecordingChange(true)
            window?.makeFirstResponder(recorder)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityIdentifier() -> String { accessibility.identifier }
        override func accessibilityLabel() -> String? { accessibility.label }
        override func accessibilityValue() -> Any? { accessibility.value }
        override func isAccessibilityEnabled() -> Bool { accessibility.isEnabled }
        override func accessibilityChildren() -> [Any]? { [] }
        override func accessibilityHitTest(_: NSPoint) -> Any? { self }

        override func accessibilityPerformPress() -> Bool {
            guard accessibility.isEnabled else { return false }
            startRecording()
            return true
        }

        override func layout() {
            super.layout()
            recorder.frame = bounds
        }
    }
}
