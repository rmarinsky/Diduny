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

/// Meeting Copy (Roman, 2026-11-17): "Copy" copies all. After a copy it reads "Copy new" (only text since then,
/// the unfinished line again) and a chevron slides in with "Copy all". "Copied" stays for `copiedHold`.
struct CopyNewButton: View {
    let copiedAt: Date?
    let hasNew: Bool
    let onCopyNew: () -> Void
    let onCopyAll: () -> Void
    var presenter: FloatingSurfacePresenter = .shared

    static let menuOwner = "livePanel.copyMenu"
    private static let copyAllRow = "copyAll"
    private static let chevronWidth: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var showsCopied = false
    @State private var anchor = FloatingSurfaceAnchor()

    private var hasCopied: Bool { copiedAt != nil }

    var body: some View {
        HStack(spacing: DS.Panel.borderWidth) {
            Button(action: hasCopied ? onCopyNew : onCopyAll) {
                part {
                    Text(showsCopied ? "Copied" : hasCopied ? "Copy new" : "Copy")
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : DS.Motion.easeOut(DS.Motion.m17CopyLabel.duration), value: showsCopied)
                }
                .frame(maxWidth: .infinity)
                .opacity(isEnabled && (!hasCopied || hasNew) ? 1 : 0.5)
            }
            .buttonStyle(PressScaleButtonStyle(scale: DS.Motion.pressScale))
            .disabled(hasCopied && !hasNew)
            .help(hasCopied ? "Copy text added since the last copy" : "Copy the whole transcript")
            .accessibilityLabel(hasCopied ? "Copy new text" : "Copy transcript")
            .accessibilityValue(hasCopied && !hasNew ? Text("Nothing new") : Text(verbatim: ""))
            .accessibilityIdentifier("livePanel.copy")
            if hasCopied {
                Button(action: openMenu) {
                    part {
                        Image(systemName: "chevron.down")
                            .font(.system(size: DS.Size.symbolChevron, weight: .semibold))
                    }
                    .frame(width: Self.chevronWidth)
                    .opacity(isEnabled ? 1 : 0.5)
                }
                .buttonStyle(PressScaleButtonStyle(scale: DS.Motion.pressScale))
                .help("More copy options")
                .accessibilityLabel("More copy options")
                .accessibilityIdentifier(Self.menuOwner)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panelButton, style: .continuous))
        .floatingSurfaceAnchor(anchor)
        .animation(reduceMotion ? DS.Motion.reduced : DS.Motion.easeInOut(0.22), value: hasCopied)
        .task(id: copiedAt) {
            let left = copiedAt.map { DS.Motion.copiedHold - Date().timeIntervalSince($0) } ?? 0
            showsCopied = left > 0
            guard left > 0 else { return }
            try? await Task.sleep(for: .seconds(left))
            if !Task.isCancelled { showsCopied = false }
        }
    }

    /// One half of the split: `chip` fill, square inner edge; the 1 pt gap shows the panel as the divider.
    private func part(@ViewBuilder _ label: () -> some View) -> some View {
        label()
            .font(DS.Font.headline)
            .lineLimit(1)
            .foregroundStyle(DS.Palette.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: DS.Size.panelButton, maxHeight: DS.Size.panelButton)
            .background(DS.Palette.chip)
            .contentShape(Rectangle())
    }

    private func openMenu() {
        guard let frame = anchor.screenFrame else { return }
        let model = PickerMenuModel(
            groups: [PickerMenuGroup(id: "copy", rows: [PickerMenuRow(id: Self.copyAllRow, title: String(localized: "Copy all"))])],
            selectedID: nil, search: .never
        )
        let onCopyAll = onCopyAll
        presenter.toggleMenu(
            owner: Self.menuOwner, model: model, alignment: .leading, anchor: frame, parent: anchor.window,
            fromKeyboard: NSApp.currentEvent?.type == .keyDown,
            onPick: { if $0 == Self.copyAllRow { onCopyAll() } }
        )
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
