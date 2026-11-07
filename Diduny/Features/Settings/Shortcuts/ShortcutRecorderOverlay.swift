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
/// Accessibility hit tests on the overlay answer with the styled field (`fieldIdentifier`), so the
/// field the person sees is the element at its own point (hittable), while clicks still reach the
/// recorder. VoiceOver still reaches the recorder through the element tree.
struct ShortcutRecorderOverlay: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    /// Accessibility identifier of the `ShortcutField` under the overlay.
    var fieldIdentifier: String?
    @Binding var isRecording: Bool
    let onChange: () -> Void

    func makeNSView(context _: Context) -> Container {
        Container(name: name, onRecordingChange: { isRecording = $0 }, onChange: onChange)
    }

    func updateNSView(_ nsView: Container, context _: Context) {
        nsView.recorder.shortcutName = name
        nsView.fieldIdentifier = fieldIdentifier
    }

    final class Container: NSView {
        private(set) var recorder: KeyboardShortcuts.RecorderCocoa!
        private let onRecordingChange: (Bool) -> Void
        private var endEditingObserver: NSObjectProtocol?
        var fieldIdentifier: String?

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

        override func accessibilityHitTest(_ point: NSPoint) -> Any? {
            guard let fieldIdentifier, let root = window?.contentView,
                  let field = Self.element(fieldIdentifier, in: root)
            else { return super.accessibilityHitTest(point) }
            return field
        }

        /// SwiftUI's elements answer the NSAccessibility getters without conforming to the protocol,
        /// so they are read by key.
        private static func element(_ identifier: String, in element: Any) -> Any? {
            guard let object = element as? NSObject else { return nil }
            func value(_ key: String) -> Any? {
                object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
            }
            if value("accessibilityIdentifier") as? String == identifier { return object }
            for child in value("accessibilityChildren") as? [Any] ?? [] {
                if let hit = self.element(identifier, in: child) { return hit }
            }
            return nil
        }

        override func mouseDown(with _: NSEvent) {
            onRecordingChange(true)
            window?.makeFirstResponder(recorder)
        }

        override func layout() {
            super.layout()
            recorder.frame = bounds
        }
    }
}
