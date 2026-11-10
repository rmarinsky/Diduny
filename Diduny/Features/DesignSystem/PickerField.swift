import AppKit
import SwiftUI

extension DS {
    /// Picker field metrics (design-spec 4.1).
    enum Field {
        static let inlineHorizontalPadding: CGFloat = 10
        static let stackedVerticalPadding: CGFloat = 5
        static let stackedHorizontalPadding: CGFloat = 9
        static let pairHorizontalPadding: CGFloat = DS.Space.sm
        static let stackedColumnGap: CGFloat = DS.Space.xs
        /// Stacked rows as the prototype lays them out: 5 + 14.8 label row + 17.2 value row + 5 = 42.
        static let stackedLabelRowHeight: CGFloat = 14.8
        static let stackedValueRowHeight: CGFloat = 17.2
        static let chevronSize: CGFloat = 9
        static let disabledOpacity: Double = 0.5
    }
}

/// One picker for every engine, language, pair and "Starts in" choice (design-spec 4.1). A button that opens a
/// `PickerMenu` on its own floating surface; not `Picker` or `Menu` (reason in 4.2).
struct PickerField: View {
    enum Layout: Equatable {
        /// 30 high: label left, value and chevron right; with no label, value left and chevron right.
        case inline
        /// 42 high: label on its own line, value and chevron under it.
        case stacked
        /// Stacked inside a pair: 12 pt value, 8 pt side padding.
        case stackedInPair
    }

    private let label: LocalizedStringKey?
    private let value: String
    private let layout: Layout
    private let menuAlignment: FloatingSurfacePlacement.Alignment
    private let identifier: String
    private let presenter: FloatingSurfacePresenter
    /// Nil for a static field (one option only).
    private let menu: (() -> PickerMenuModel)?
    private let onPick: (String) -> Void
    /// After a mouse pick of a row this accepts, puts a pointer that ended up outside the window back on this field.
    private let returnsPointerOnPick: (String) -> Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var anchor = FloatingSurfaceAnchor()

    /// - Parameters:
    ///   - identifier: accessibility identifier (test-plan 2.1, e.g. `livePanel.engine`); also the menu's owner id.
    ///   - menuAlignment: `.trailing` for the right field of a pair and "Translate into" on the command home.
    ///   - menu: built when the menu opens.
    init(
        label: LocalizedStringKey?,
        value: String,
        layout: Layout = .inline,
        menuAlignment: FloatingSurfacePlacement.Alignment = .leading,
        identifier: String,
        presenter: FloatingSurfacePresenter = .shared,
        returnsPointerOnPick: @escaping (String) -> Bool = { _ in false },
        menu: @escaping () -> PickerMenuModel,
        onPick: @escaping (String) -> Void
    ) {
        self.label = label
        self.value = value
        self.layout = layout
        self.menuAlignment = menuAlignment
        self.identifier = identifier
        self.presenter = presenter
        self.returnsPointerOnPick = returnsPointerOnPick
        self.menu = menu
        self.onPick = onPick
    }

    /// A static field: `box` fill, value in `text`, no chevron, not focusable (`.field.static` P:73).
    init(staticLabel label: LocalizedStringKey?, value: String, layout: Layout = .inline, identifier: String) {
        self.label = label
        self.value = value
        self.layout = layout
        menuAlignment = .leading
        self.identifier = identifier
        presenter = .shared
        returnsPointerOnPick = { _ in false }
        menu = nil
        onPick = { _ in }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
    }

    var body: some View {
        if menu == nil {
            content(valueColor: DS.Palette.text, showsChevron: false)
                .background(DS.Palette.box, in: shape)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier(identifier)
                .disabled(true)
        } else {
            interactive
        }
    }

    private var interactive: some View {
        let isOpen = presenter.isOpen(owner: identifier)
        return Button { open(fromKeyboard: false) } label: {
            content(valueColor: DS.Palette.accentText, showsChevron: true)
                .background(DS.Palette.tint, in: shape)
                .overlay {
                    // Hover and open: inner 1 pt accent border, no transition (M13).
                    if isEnabled, isHovered || isOpen {
                        shape.strokeBorder(DS.Palette.accent, lineWidth: DS.Panel.borderWidth)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(PressScaleButtonStyle(scale: DS.Motion.fieldPressScale))
        .focusable()
        .contentShape(.focusEffect, shape)
        .onKeyPress(keys: [.space, .return]) { _ in
            open(fromKeyboard: true)
            return .handled
        }
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1 : DS.Field.disabledOpacity)
        .floatingSurfaceAnchor(anchor)
        .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: value))
        .accessibilityValue(Text(verbatim: value))
        .accessibilityHint(Text("Opens a list"))
        .accessibilityIdentifier(identifier)
    }

    private func open(fromKeyboard: Bool) {
        guard isEnabled, let menu, let frame = anchor.screenFrame else { return }
        let window = anchor.window
        let returnsPointer = returnsPointerOnPick
        let onPick = onPick
        presenter.toggleMenu(
            owner: identifier, model: menu(), alignment: menuAlignment, anchor: frame,
            parent: window, fromKeyboard: fromKeyboard,
            onPick: { row in
                if NSApp.currentEvent?.type != .keyDown, returnsPointer(row), let window, let target = PointerReturn.target(
                    pointer: NSEvent.mouseLocation, windowFrame: window.frame, field: frame,
                    primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0
                ) {
                    CGWarpMouseCursorPosition(target)
                }
                onPick(row)
            }
        )
    }

    @ViewBuilder
    private func content(valueColor: Color, showsChevron: Bool) -> some View {
        switch layout {
        case .inline:
            HStack(spacing: DS.Space.sm) {
                if let label {
                    Text(label)
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.secondary)
                        .fixedSize()
                }
                // Gaps label 8 value 8 chevron: the value takes the free width, trailing after a label.
                valueText(font: DS.Font.headline, color: valueColor, alignment: label == nil ? .leading : .trailing)
                if showsChevron { chevron(valueColor) }
            }
            .padding(.horizontal, DS.Field.inlineHorizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Size.fieldInline)
        case .stacked, .stackedInPair:
            VStack(alignment: .leading, spacing: 0) {
                if let label {
                    Text(label)
                        .font(DS.Font.fieldLabel)
                        .foregroundStyle(DS.Palette.secondary)
                        .fixedSize()
                        .frame(height: DS.Field.stackedLabelRowHeight)
                }
                HStack(spacing: DS.Field.stackedColumnGap) {
                    valueText(
                        font: layout == .stackedInPair ? DS.Font.calloutStrong : DS.Font.contentStrong,
                        color: valueColor,
                        alignment: .leading
                    )
                    if showsChevron { chevron(valueColor) }
                }
                .frame(height: DS.Field.stackedValueRowHeight)
            }
            .padding(.vertical, DS.Field.stackedVerticalPadding)
            .padding(
                .horizontal,
                layout == .stackedInPair ? DS.Field.pairHorizontalPadding : DS.Field.stackedHorizontalPadding
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DS.Size.fieldStacked)
        }
    }

    private func valueText(font: Font, color: Color, alignment: Alignment) -> some View {
        Text(verbatim: value)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func chevron(_ color: Color) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: DS.Field.chevronSize, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Where to warp a pointer back to after a menu pick (AppKit y up, one origin for all displays; CG y down from
/// the top of the primary display). Nil when the pointer is still inside the window.
enum PointerReturn {
    static func target(pointer: NSPoint, windowFrame: NSRect, field: NSRect, primaryScreenMaxY: CGFloat) -> CGPoint? {
        guard !windowFrame.contains(pointer) else { return nil }
        return CGPoint(x: field.midX, y: primaryScreenMaxY - field.midY)
    }
}

// MARK: - Anchor

/// Where a floating surface hangs from: the trigger's frame on screen and its window (the surface's parent).
@MainActor
final class FloatingSurfaceAnchor {
    fileprivate weak var view: NSView?

    var window: NSWindow? {
        view?.window
    }

    var screenFrame: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

extension View {
    /// Records this view's frame for a floating surface trigger (picker field, popup button).
    func floatingSurfaceAnchor(_ anchor: FloatingSurfaceAnchor) -> some View {
        background(FloatingSurfaceAnchorReader(anchor: anchor))
    }
}

private struct FloatingSurfaceAnchorReader: NSViewRepresentable {
    let anchor: FloatingSurfaceAnchor

    func makeNSView(context _: Context) -> NSView {
        let view = AnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        anchor.view = view
    }

    /// Takes no clicks; it only measures.
    private final class AnchorView: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
}
