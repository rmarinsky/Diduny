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
    /// Identifier of the title text, for rows whose title is the value (Languages lists, test-plan 2.1).
    var titleIdentifier: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.text)
                        .accessibilityIdentifier(ifPresent: titleIdentifier)
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
                controls
            }
            .padding(.vertical, 9)
            if showsHairline {
                Rectangle().fill(DS.Palette.line).frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// With a caption the control takes the row label as its label and the caption as its hint
    /// (spec 4.10); without one it keeps its own label. Button and segmented rows hold several
    /// controls with their own text ("Record" and "Play", keys, count and switch), so each keeps its
    /// own label and only gets the hint: one shared label would hide which control is which.
    @ViewBuilder private var controls: some View {
        let cluster = HStack(spacing: DS.Space.sm) { control() }
            .fixedSize()
            .frame(height: kind.slotHeight)
        if let caption, kind == .button || kind == .segmented {
            cluster.accessibilityHint(Text(caption))
        } else if let caption {
            cluster
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(caption))
        } else {
            cluster
        }
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
                .font(.system(size: DS.Size.symbolChevron, weight: .semibold))
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
                .font(.system(size: DS.Size.symbolSmall, weight: .medium))
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
