import SwiftUI

/// Panel header link (design-spec 4.19): 12 `secondary`, padding 4 x 6, radius 6, 23 high;
/// on hover `text` on `chip`, instantly (M13). "Recordings", "Settings", "Batch files & URLs".
struct HeaderLink: View {
    let title: LocalizedStringKey
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.callout)
                .foregroundStyle(isHovered ? DS.Palette.text : DS.Palette.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: DS.Size.headerLink)
                .background(isHovered ? DS.Palette.chip : Color.clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.headerLink, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.headerLink, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Inline link (4.19): `accentText` semibold at the surrounding font size, underline on hover.
/// Set the size with `.font(...)` on it or a parent. "Use Cloud", "Show original text", language
/// counts (with `showsChevron`, a 9 pt chevron 4 apart), "Your key".
struct InlineLink: View {
    let title: LocalizedStringKey
    var showsChevron = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                    .underline(isHovered)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(DS.Palette.accentText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
