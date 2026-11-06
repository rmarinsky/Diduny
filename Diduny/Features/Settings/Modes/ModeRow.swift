import AppKit
import KeyboardShortcuts
import SwiftUI

/// Modes grid columns (design-spec 7.11, D11): 150 / 1.1 fr / 1 fr / 162 / 26, gap 10.
enum ModesGrid {
    static let modeColumn: CGFloat = 150
    static let shortcutColumn: CGFloat = 162
    static let gap: CGFloat = 10
    static let engineShare: CGFloat = 1.1
    /// Expanded options start under the Engine column (`.mdet`).
    static let detailIndent: CGFloat = modeColumn + gap
    static let detailFieldWidth: CGFloat = 200
    static let rowPadding: CGFloat = 10
    static let cellMinHeight: CGFloat = 30

    /// Engine and second-choice widths for the content width (1.1 : 1 of what is left).
    static func flexibleWidths(total: CGFloat) -> (engine: CGFloat, second: CGFloat) {
        let rest = max(total - modeColumn - shortcutColumn - DS.Size.expander - gap * 4, 0)
        let engine = rest * engineShare / (engineShare + 1)
        return (engine, rest - engine)
    }
}

/// One mode row (design-spec 4.11): name, engine field with caption, second choice, shortcut and count, expander.
struct ModeRow<Second: View>: View {
    let job: STTJob
    let title: String
    let symbol: String
    let widths: (engine: CGFloat, second: CGFloat)
    @Bindable var model: ModesViewModel
    let shortcut: KeyboardShortcuts.Name?
    /// Files and URLs: "⇧⌘B", a fixed menu command, shown disabled with no count (05 2.1).
    var fixedShortcut: String?
    @ViewBuilder var second: () -> Second

    private var id: String { "modes.\(job.rawValue)" }

    var body: some View {
        HStack(alignment: .top, spacing: ModesGrid.gap) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: symbol)
                    .font(.system(size: DS.Size.symbolTile))
                    .foregroundStyle(DS.Palette.accent)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Palette.text)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(width: ModesGrid.modeColumn, alignment: .leading)
            .frame(minHeight: ModesGrid.cellMinHeight)

            VStack(alignment: .leading, spacing: 3) {
                engineField
                Text(verbatim: model.caption(for: job))
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("\(id).engine.caption")
            }
            .frame(width: widths.engine, alignment: .leading)

            second()
                .frame(width: widths.second, alignment: .leading)

            shortcutCell
                .frame(width: ModesGrid.shortcutColumn, alignment: .leading)
                .frame(minHeight: ModesGrid.cellMinHeight)

            if job == .file {
                Color.clear.frame(width: DS.Size.expander, height: DS.Size.expander)
            } else {
                ExpanderButton(isExpanded: model.expandedJob == job, accessibilityLabel: "\(title) options") {
                    model.toggleExpander(job)
                }
                .padding(.top, 2)
                .accessibilityIdentifier("\(id).expand")
            }
        }
        .padding(.vertical, ModesGrid.rowPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modes.row.\(job.rawValue)")
    }

    @ViewBuilder private var engineField: some View {
        let segment = job == .meeting ? model.startsIn : nil
        let value = model.engineName(model.engine(for: job))
        if model.isStatic(job: job, segment: segment) {
            PickerField(staticLabel: nil, value: value, identifier: "\(id).engine")
        } else {
            PickerField(label: nil, value: value, identifier: "\(id).engine") {
                model.engineMenu(job: job, segment: segment)
            } onPick: { model.pickEngine($0, job: job) }
        }
    }

    @ViewBuilder private var shortcutCell: some View {
        if let fixedShortcut {
            ShortcutField(shortcut: fixedShortcut, rowLabel: title)
                .disabled(true)
                .accessibilityIdentifier("\(id).shortcut")
        } else if let shortcut {
            HStack(spacing: 6) {
                ModeShortcutRecorder(name: shortcut, rowLabel: title)
                    .accessibilityIdentifier("\(id).shortcut")
                ShortcutPressCountPicker(selection: Binding(
                    get: { model.pressCount(for: job) },
                    set: { model.setPressCount($0, for: job) }
                ))
                .accessibilityIdentifier("\(id).pressCount")
            }
        }
    }
}

/// `ShortcutField` with the invisible `KeyboardShortcuts` recorder laid over it (spec 4.14 building blocks).
/// The recorder handles Escape (keeps the old value) and ignores a modifier alone.
struct ModeShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    let rowLabel: String

    @State private var isRecording = false
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        ShortcutField(shortcut: KeyboardShortcuts.getShortcut(for: name)?.description, rowLabel: rowLabel, isRecording: isRecording)
            .overlay {
                RecorderOverlay(name: name, isRecording: $isRecording) { refresh += 1 }
                    .accessibilityHidden(true)
            }
    }

    private struct RecorderOverlay: NSViewRepresentable {
        let name: KeyboardShortcuts.Name
        @Binding var isRecording: Bool
        let onChange: () -> Void

        func makeNSView(context _: Context) -> Container {
            Container(name: name, onRecording: { isRecording = $0 }, onChange: onChange)
        }

        func updateNSView(_ view: Container, context _: Context) {
            view.recorder.shortcutName = name
        }

        final class Container: NSView {
            let recorder: KeyboardShortcuts.RecorderCocoa
            private var observers: [NSObjectProtocol] = []
            private let onRecording: (Bool) -> Void

            init(name: KeyboardShortcuts.Name, onRecording: @escaping (Bool) -> Void, onChange: @escaping () -> Void) {
                recorder = KeyboardShortcuts.RecorderCocoa(for: name) { _ in onChange() }
                self.onRecording = onRecording
                super.init(frame: .zero)
                recorder.alphaValue = 0.01
                recorder.focusRingType = .none
                addSubview(recorder)
                let center = NotificationCenter.default
                observers = [
                    center.addObserver(forName: NSControl.textDidBeginEditingNotification, object: recorder, queue: .main) { _ in onRecording(true) },
                    center.addObserver(forName: NSControl.textDidEndEditingNotification, object: recorder, queue: .main) { _ in onRecording(false) },
                ]
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

            deinit { observers.forEach(NotificationCenter.default.removeObserver) }

            override var mouseDownCanMoveWindow: Bool { false }
            override func hitTest(_ point: NSPoint) -> NSView? {
                bounds.contains(convert(point, from: superview)) ? self : nil
            }

            override func mouseDown(with _: NSEvent) {
                if window?.makeFirstResponder(recorder) == true { onRecording(true) }
            }

            override func layout() {
                super.layout()
                recorder.frame = bounds
            }
        }
    }
}
