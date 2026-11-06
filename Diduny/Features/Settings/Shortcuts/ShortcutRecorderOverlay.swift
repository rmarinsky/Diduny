import AppKit
import KeyboardShortcuts
import SwiftUI

/// Builds the capture field for the two rows the package recorder cannot take (ADR-0012 D8):
/// Cancel (any key) and in place (modifier-only or key chord). WP-15's `ShortcutCaptureField`
/// is plugged in here; the view lays the result over the styled `ShortcutField`.
@MainActor
protocol ShortcutCaptureFieldProviding {
    func captureField(for row: ShortcutRow, isRecording: Binding<Bool>, onCommit: @escaping () -> Void) -> AnyView
}

/// Until WP-15 lands: no capture, the two fields only show the stored value.
struct NoShortcutCaptureField: ShortcutCaptureFieldProviding {
    func captureField(for _: ShortcutRow, isRecording _: Binding<Bool>, onCommit _: @escaping () -> Void) -> AnyView {
        AnyView(EmptyView())
    }
}

/// Invisible `KeyboardShortcuts.RecorderCocoa` laid over the styled field (spec 4.14, D8). A click
/// anywhere on the field starts recording; the recorder's own Escape keeps the old value. The
/// visible layer, "Press keys..." and the accent border, is `ShortcutField` driven by `isRecording`.
///
/// The recorder fills the whole field: it cancels recording on a mouse-up outside its own bounds.
struct ShortcutRecorderOverlay: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    @Binding var isRecording: Bool
    let onChange: () -> Void

    func makeNSView(context _: Context) -> Container {
        Container(name: name, onRecordingChange: { isRecording = $0 }, onChange: onChange)
    }

    func updateNSView(_ nsView: Container, context _: Context) {
        nsView.recorder.shortcutName = name
    }

    final class Container: NSView {
        private(set) var recorder: KeyboardShortcuts.RecorderCocoa!
        private let onRecordingChange: (Bool) -> Void
        private var endEditingObserver: NSObjectProtocol?

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
