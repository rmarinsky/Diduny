import SwiftUI

/// Command panel tile (design-spec 4.6): `card` fill, 16 pt accent symbol spanning both lines,
/// title (up to 2 lines) over a one-line caption. 47 high with a one-line title, 62 with two;
/// it fills the height its grid row gives it, so both tiles in a row match the taller one.
struct CommandTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
                    // The prototype's icons are 16 wide; SF `person.2` is wider. Keep the 16 pt
                    // column so the text column stays 89 pt in a 133 pt tile (spec 4.6).
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Font.contentStrong)
                        .foregroundStyle(DS.Palette.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(caption)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                isHovered && isEnabled ? DS.Palette.tint : DS.Palette.card,
                in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .animation(DS.Motion.easeOut(DS.Motion.m12TileHover.duration), value: isHovered)
        }
        .buttonStyle(PressScaleButtonStyle(scale: DS.Motion.pressScale))
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(title) + Text(verbatim: ", ") + Text(caption))
    }
}
