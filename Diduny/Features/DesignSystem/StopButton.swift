import SwiftUI

/// Stop (design-spec 4.4): `accentFill`, white square, "Stop" over the cancel hint, keycap at the
/// trailing edge. Fills the width its row gives it (1.6 parts of the controls row).
struct StopButton: View {
    /// For example "Cancel: Esc ×3" (`store.cancelShortcutHint`); nil hides the line.
    let cancelHint: String?
    /// For example "⌥ ×2" (`store.stopShortcutHint`); nil hides the keycap.
    let shortcut: String?
    /// Built by the caller as today: "Stop and process recording. ⌥ ×2 also stops. Esc ×3 cancels".
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                // The prototype's spacer sits between two 8 pt gaps; here one 8 pt gap stays
                // before the keycap, so "Cancel: Esc ×3" fits the 164 pt share without truncating.
                HStack(spacing: DS.Space.sm) {
                    RoundedRectangle(cornerRadius: DS.Radius.stopGlyph, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Stop").font(DS.Font.headline)
                        if let cancelHint {
                            Text(verbatim: cancelHint)
                                .font(DS.Font.footnote)
                                .lineLimit(1)
                                .accessibilityIdentifier("livePanel.stop.cancelHint")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut {
                    Keycap(text: shortcut).accessibilityIdentifier("livePanel.stop.keycap")
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: DS.Size.panelButton, maxHeight: DS.Size.panelButton)
            .background(DS.Palette.accentFill, in: RoundedRectangle(cornerRadius: DS.Radius.panelButton, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panelButton, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: DS.Motion.pressScale))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(Text("Stop"))
        .accessibilityHint(Text(verbatim: accessibilityHint))
    }
}

/// Stop keycap: 10 semibold rounded, white 1 pt border, no fill, 20 high (D17).
struct Keycap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.keycap)
            .lineLimit(1)
            // CSS padding 3 x 5 plus the 1 pt border, which `strokeBorder` draws inside.
            .padding(.horizontal, 6)
            .frame(height: DS.Size.keycapHeight)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.keycap, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 1)
            )
    }
}
