import SwiftUI

/// One Settings row (design-spec 4.10): label (13) over an optional caption (11.5, line height
/// 16.1), control cluster trailing and centred across both lines, 16 apart, 9 pt vertical padding,
/// 1 pt `line` hairline at the bottom. Replaces `SettingsGroup` + `Card` + `SettingRow` on the
/// redesigned pages.
struct SettingsLineRow<Control: View>: View {
    /// The control the row holds. Native controls keep their system size; the row lays them out
    /// in the prototype's control height (spec 3.2: switch 20, segmented 23, button 25, pop-up 28),
    /// so rows are 39 / 42 / 44 / 47 high whatever the system draws. A taller native control
    /// (the macOS 26 switch is 24) is centred and overhangs into the 9 pt row padding.
    enum Kind {
        case toggle, segmented, button, popUp, other

        var slotHeight: CGFloat? {
            switch self {
            case .toggle: 20
            case .segmented: 23
            case .button: 25
            case .popUp: 28
            case .other: nil
            }
        }
    }

    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    var kind: Kind = .other
    /// Off for the last row inside an expander or a popup.
    var showsHairline = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.text)
                    if let caption {
                        Text(caption)
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Palette.secondary)
                            .lineSpacing(DS.Font.LineSpacing.rowCaption)
                            // CSS line height puts half the leading above the first line and
                            // below the last; `lineSpacing` only adds it between lines.
                            .padding(.vertical, DS.Font.LineSpacing.rowCaption / 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: DS.Space.sm) { control() }
                    .fixedSize()
                    .frame(height: kind.slotHeight)
            }
            .padding(.vertical, 9)
            if showsHairline {
                Rectangle().fill(DS.Palette.line).frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityHint(caption.map { Text($0) } ?? Text(verbatim: ""))
    }
}

/// Native switch (design-spec 4.13, D4). The title is the accessibility label; it is not drawn.
struct SettingsSwitch: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(DS.Palette.accent)
    }
}

/// Modes row expander (4.11 item 5): 26 pt, no fill, `chip` on hover, chevron turns 180° (M14).
struct ExpanderButton: View {
    let isExpanded: Bool
    /// "<mode> options".
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.Palette.secondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .animation(reduceMotion ? nil : DS.Motion.easeOut(DS.Motion.m14Expander.duration), value: isExpanded)
                .frame(width: DS.Size.expander, height: DS.Size.expander)
                .background(isHovered ? DS.Palette.chip : Color.clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(verbatim: isExpanded ? "expanded" : "collapsed"))
    }
}

/// Local models delete (4.12): 24 pt, `trash` 12 pt `secondary`; on hover `chip` fill and `no` glyph.
struct TrashButton: View {
    /// "Delete <model>".
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? DS.Palette.no : DS.Palette.secondary)
                .frame(width: DS.Size.trash, height: DS.Size.trash)
                .background(isHovered ? DS.Palette.chip : Color.clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(accessibilityLabel))
    }
}
