import SwiftUI

/// Providers and Local models marks (design-spec 4.8): 20 x 20 in tables, 16 x 16 in the legend.
/// Two marks in one cell sit 12 apart; the cell builds its own combined accessibility label.
struct CapabilityMark: View {
    enum Kind: String, CaseIterable, Sendable {
        /// The engine does it: white check on `okFill`.
        case yes
        /// By Diduny: right half filled, `accent`.
        case byDiduny
        /// Not available: outlined cross, `no`.
        case no
    }

    let kind: Kind
    var size: CGFloat = DS.Size.mark

    var body: some View {
        symbol
            .font(.system(size: size, weight: .regular))
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(label)
    }

    @ViewBuilder private var symbol: some View {
        switch kind {
        case .yes:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, DS.Palette.okFill)
        case .byDiduny:
            Image(systemName: "circle.righthalf.filled").foregroundStyle(DS.Palette.accent)
        case .no:
            Image(systemName: "xmark.circle").foregroundStyle(DS.Palette.no)
        }
    }

    private var label: Text {
        switch kind {
        case .yes: Text("Yes")
        case .byDiduny: Text("By Diduny")
        case .no: Text("No")
        }
    }
}
