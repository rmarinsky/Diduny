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

/// The two captioned groups of the meeting panel (option A), as CSS `flex: 1 1 auto` and `flex: 0 1 auto`:
/// the second keeps its ideal width and the first takes the rest. A short track shrinks both in proportion.
/// `ModeSegmentsLayout` fills whatever it is offered, so an `HStack` would give one group all the room.
struct MeetingSegmentGroupsLayout: Layout {
    var spacing: CGFloat = 6

    static func widths(first: CGFloat, second: CGFloat, available: CGFloat, spacing: CGFloat) -> [CGFloat] {
        let room = max(available - spacing, 0)
        let total = first + second
        guard total > room else { return [room - second, second] }
        guard total > 0 else { return [0, 0] }
        return [first * room / total, second * room / total]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? idealWidth, height: ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 2 else { return }
        let widths = Self.widths(
            first: subviews[0].sizeThatFits(.unspecified).width,
            second: subviews[1].sizeThatFits(.unspecified).width,
            available: bounds.width,
            spacing: spacing
        )
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: widths[0], height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + widths[0] + spacing, y: bounds.minY),
            proposal: ProposedViewSize(width: widths[1], height: bounds.height)
        )
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
    /// An arrow pressed at the last segment: the next group takes it (-1 or +1).
    var onStepPastEnd: ((Int) -> Void)?
    /// Set: arrows only move this focus, and Space or Return commits. For a choice that has an effect the moment
    /// it is made, such as a mid-meeting switch.
    var focus: FocusState<ID?>.Binding?

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
            ForEach(items, id: \.id) { item in
                ModeSegmentButton(title: item.title, isSelected: item.id == selection) {
                    selection = item.id
                }
                .disabled(!item.isEnabled)
                .accessibilityIdentifier(ifPresent: item.accessibilityID)
                .modifier(SegmentFocus(id: item.id, focus: focus))
            }
        }
        .padding(DS.Size.segmentInset)
        .background(DS.Palette.chip, in: RoundedRectangle(cornerRadius: DS.Radius.segmentTrack, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.return) {
            guard let focus, let focused = focus.wrappedValue else { return .ignored }
            selection = focused
            return .handled
        }
    }

    private func move(_ direction: Int) -> KeyPress.Result {
        let current = focus?.wrappedValue ?? selection
        let next = Self.step(from: current, by: direction, in: items)
        if next == current, let onStepPastEnd {
            onStepPastEnd(direction)
        } else if let focus {
            focus.wrappedValue = next
        } else {
            selection = next
        }
        return .handled
    }
}

private struct SegmentFocus<ID: Hashable>: ViewModifier {
    let id: ID
    let focus: FocusState<ID?>.Binding?

    func body(content: Content) -> some View {
        if let focus {
            content.focusable().focused(focus, equals: id)
        } else {
            content
        }
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

extension View {
    /// Sets the accessibility identifier only when there is one.
    @ViewBuilder func accessibilityIdentifier(ifPresent identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
