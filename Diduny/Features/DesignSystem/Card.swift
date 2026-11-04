import SwiftUI

/// Radius 12, border primary 8%, controlBackground fill. Default padding 16; pass 0 for row groups.
struct Card<Content: View>: View {
    var padding: CGFloat = DS.Space.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.cardFill, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
            )
    }
}

/// Title (body) + optional subtitle (callout secondary) left, control right, min height 44.
struct SettingRow<Control: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.body)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.lg)
            control()
        }
        .padding(.vertical, DS.Space.md)
        .padding(.horizontal, DS.Space.lg)
        .frame(minHeight: DS.Layout.settingRowMinHeight)
    }
}

/// Settings group: a padding-0 Card whose rows are separated by 1 pt hairlines at 8%.
struct SettingsGroup<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let title {
                Text(title).font(DS.Font.headline)
            }
            Card(padding: 0) {
                VStack(spacing: 0) { content() }
            }
        }
    }
}

struct RowSeparator: View {
    var body: some View {
        Rectangle().fill(DS.Palette.separator).frame(height: 1)
    }
}

/// `:active` scale .97 in 120 ms ease-out for plain custom buttons; no scale under reduced motion.
struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .animation(DS.Motion.easeOut(0.12), value: configuration.isPressed)
    }
}
