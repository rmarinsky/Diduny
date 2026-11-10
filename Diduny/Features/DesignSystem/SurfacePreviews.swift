import SwiftUI

/// Where the recording shows (design-spec 9.2): a drawn screen with the floating panel or the
/// Dynamic Notch, from tokens so it follows light and dark.
enum SurfacePreviewKind: CaseIterable {
    case floatingPanel, dynamicNotch

    var title: LocalizedStringKey {
        switch self {
        case .floatingPanel: "Floating panel"
        case .dynamicNotch: "Dynamic Notch"
        }
    }
}

/// 132 x 78 drawing; coordinates from the prototype's `scr` and `PV` (P:727-728), top-left origin.
/// Hidden from accessibility: the tile's label carries the meaning.
struct SurfacePreviewDrawing: View {
    let kind: SurfacePreviewKind

    /// The notch is black in both appearances; only inside this drawing.
    private static let notch = Color(red: 0, green: 0, blue: 0)
    private static let notchLine = Color(red: 0x8A / 255, green: 0x8A / 255, blue: 0x8F / 255)

    var body: some View {
        ZStack(alignment: .topLeading) {
            rect(x: 1, y: 1, width: 130, height: 76, radius: DS.Radius.previewDrawing, fill: DS.Palette.box, stroke: true)
            rect(x: 1, y: 1, width: 130, height: 9, radius: 4, fill: DS.Palette.chip)
            switch kind {
            case .floatingPanel:
                rect(x: 100, y: 16, width: 26, height: 36, radius: 4, fill: DS.Palette.panel, stroke: true)
                rect(x: 103, y: 19, width: 8, height: 5, radius: 1.5, fill: DS.Palette.accent)
                rect(x: 103, y: 28, width: 20, height: 14, radius: 2, fill: DS.Palette.chip)
                rect(x: 113, y: 45, width: 10, height: 4, radius: 1.5, fill: DS.Palette.accent)
            case .dynamicNotch:
                rect(x: 44, y: 1, width: 44, height: 13, radius: 5, fill: Self.notch)
                rect(x: 50, y: 5, width: 2, height: 5, radius: 1, fill: DS.Palette.accent)
                rect(x: 54, y: 4, width: 2, height: 7, radius: 1, fill: DS.Palette.accent)
                rect(x: 58, y: 6, width: 2, height: 3, radius: 1, fill: DS.Palette.accent)
                rect(x: 66, y: 6, width: 18, height: 3, radius: 1.5, fill: Self.notchLine)
            }
        }
        .frame(width: 132, height: 78, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// SVG strokes sit on the edge (half in, half out), so the 1 pt line is drawn centred.
    private func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat,
                      fill: Color, stroke: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape.fill(fill)
            .overlay { if stroke { shape.stroke(DS.Palette.line, lineWidth: 1) } }
            .frame(width: width, height: height)
            .offset(x: x, y: y)
    }
}

/// Preview tile (`.pv button` P:190): drawing over a 12 pt label, padding 4, radius 8; selected:
/// 2 pt `accent` ring outside the tile and the label in `text` semibold.
struct SurfacePreviewTile: View {
    let kind: SurfacePreviewKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                SurfacePreviewDrawing(kind: kind)
                Text(kind.title)
                    .font(isSelected ? DS.Font.calloutStrong : DS.Font.callout)
                    .foregroundStyle(isSelected ? DS.Palette.text : DS.Palette.secondary)
            }
            .padding(4)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: DS.Radius.previewTile + 1, style: .continuous)
                        .stroke(DS.Palette.accent, lineWidth: 2)
                        .padding(-1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.previewTile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(kind.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
