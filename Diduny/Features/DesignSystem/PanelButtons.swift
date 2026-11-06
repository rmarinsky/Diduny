import SwiftUI

/// Copy, New recording, Not now (neutral, `chip`) and Open recording, Start recording (primary,
/// `accentFill`): 38 high, 13 semibold, centred label, no symbol (design-spec 4.5).
struct PanelButton: View {
    enum Role { case neutral, primary }

    let title: LocalizedStringKey
    var role: Role = .neutral
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelButtonLabel(role: role) { Text(title) }
        }
        .buttonStyle(PressScaleButtonStyle(scale: DS.Motion.pressScale))
    }
}

/// Copy, then "Copied" while `isCopied` (today's `store.copiedAt`), with a text cross-fade (M17).
struct CopyButton: View {
    let isCopied: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            PanelButtonLabel(role: .neutral) {
                Text(isCopied ? "Copied" : "Copy")
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : DS.Motion.easeOut(DS.Motion.m17CopyLabel.duration), value: isCopied)
            }
        }
        .buttonStyle(PressScaleButtonStyle(scale: DS.Motion.pressScale))
    }
}

private struct PanelButtonLabel<Label: View>: View {
    let role: PanelButton.Role
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label()
            .font(DS.Font.headline)
            .lineLimit(1)
            .foregroundStyle(role == .primary ? Color.white : DS.Palette.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: DS.Size.panelButton, maxHeight: DS.Size.panelButton)
            .background(
                role == .primary ? DS.Palette.accentFill : DS.Palette.chip,
                in: RoundedRectangle(cornerRadius: DS.Radius.panelButton, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panelButton, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The panel controls row: children split the width by `weights` (Copy : Stop is 1 : 1.6,
/// two buttons 1 : 1), 8 apart, all as high as the tallest.
struct PanelControlsLayout: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = DS.Space.sm

    static func widths(available: CGFloat, weights: [CGFloat], spacing: CGFloat) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let room = max(available - spacing * CGFloat(weights.count - 1), 0)
        let total = weights.reduce(0, +)
        guard total > 0 else { return weights.map { _ in room / CGFloat(weights.count) } }
        return weights.map { room * $0 / total }
    }

    private func widths(_ width: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let weights = subviews.indices.map { $0 < self.weights.count ? self.weights[$0] : 1 }
        guard let width else { return subviews.map { $0.sizeThatFits(.unspecified).width } }
        return Self.widths(available: width, weights: weights, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let widths = widths(proposal.width, subviews)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: widths.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
