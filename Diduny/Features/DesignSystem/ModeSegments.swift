import SwiftUI

/// Segments sized as CSS `flex: 1 1 auto` with `min-width: 0` (design-spec 4.3): each takes its
/// ideal width, the rest of the track is shared equally, and a short track shrinks each one in
/// proportion to its ideal width. `HStack` with `maxWidth: .infinity` would give equal widths.
struct ModeSegmentsLayout: Layout {
    var spacing: CGFloat = DS.Size.segmentInset

    /// Widths for `ideal` segment widths in `available` points (nil: the ideal widths).
    static func widths(ideal: [CGFloat], available: CGFloat?, spacing: CGFloat) -> [CGFloat] {
        guard let available, !ideal.isEmpty else { return ideal }
        let room = max(available - spacing * CGFloat(ideal.count - 1), 0)
        let total = ideal.reduce(0, +)
        if room >= total {
            let extra = (room - total) / CGFloat(ideal.count)
            return ideal.map { $0 + extra }
        }
        guard total > 0 else { return ideal.map { _ in 0 } }
        return ideal.map { $0 * room / total }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = Self.widths(ideal: ideal.map(\.width), available: proposal.width, spacing: spacing)
        let width = widths.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: width, height: ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = Self.widths(ideal: ideal, available: bounds.width, spacing: spacing)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// This Mac / Cloud / Record only (design-spec 4.3). The selected segment is filled with the
/// brand accent and cross-fades (M9); the fill does not slide.
struct ModeSegments<ID: Hashable>: View {
    struct Item {
        let id: ID
        let title: LocalizedStringKey
        var isEnabled = true
        /// For example `livePanel.segment.cloudLive` (test-plan 2.1).
        var accessibilityID: String?
    }

    let items: [Item]
    @Binding var selection: ID
    var accessibilityLabel: LocalizedStringKey = "Transcript mode"

    /// Left (-1) and Right (+1) arrows: the nearest enabled segment that way; stops at the ends.
    static func step(from current: ID, by direction: Int, in items: [Item]) -> ID {
        guard var index = items.firstIndex(where: { $0.id == current }) else { return current }
        while true {
            index += direction
            guard items.indices.contains(index) else { return current }
            if items[index].isEnabled { return items[index].id }
        }
    }

    var body: some View {
        ModeSegmentsLayout {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ModeSegmentButton(title: item.title, isSelected: item.id == selection) {
                    selection = item.id
                }
                .disabled(!item.isEnabled)
                .accessibilityIdentifier(item.accessibilityID ?? "")
            }
        }
        .padding(DS.Size.segmentInset)
        .background(DS.Palette.chip, in: RoundedRectangle(cornerRadius: DS.Radius.segmentTrack, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
    }

    private func move(_ direction: Int) -> KeyPress.Result {
        selection = Self.step(from: selection, by: direction, in: items)
        return .handled
    }
}

/// One segment: 30 high, 0 x 6 padding, 11.5 semibold, one line.
struct ModeSegmentButton: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.segment)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : DS.Palette.secondary)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: DS.Size.segment, maxHeight: DS.Size.segment)
                .background(
                    isSelected ? DS.Palette.accentFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.segment, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.segment, style: .continuous))
                .animation(
                    reduceMotion ? nil : DS.Motion.easeOut(DS.Motion.m9SegmentSelection.duration),
                    value: isSelected
                )
        }
        .buttonStyle(PressScaleButtonStyle(scale: DS.Motion.pressScale))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
