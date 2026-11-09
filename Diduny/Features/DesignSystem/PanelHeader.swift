import SwiftUI

/// Panel header (design-spec 4.7, 4.16): icon tile, title over an optional status line, then the
/// trailing items (timer, header links, icon buttons) after a spacer. The caller keeps it the
/// drag handle.
struct PanelHeader<Icon: View, Trailing: View>: View {
    let icon: Icon
    let title: LocalizedStringKey
    var status: PanelStatus?
    /// For example `livePanel.title`, `outcome.title`, `prompt.title`.
    var titleID: String?
    /// For example `livePanel.status`, `outcome.subtitle`; its value is `live` or `notLive`.
    var statusID: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Palette.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(ifPresent: titleID)
                if let status {
                    PanelStatusLine(status: status)
                        .accessibilityIdentifier(ifPresent: statusID)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// The 11 pt line under the panel title.
enum PanelStatus {
    /// Live text running: accent dot, text in `text`.
    case live(LocalizedStringKey)
    /// No live text, prompt and outcome subtitles: `secondary`, no dot.
    case plain(LocalizedStringKey)
    /// Text in `no`.
    case error(LocalizedStringKey)

    /// Accessibility value for the dot (test-plan 2.1): `live` only while live text runs.
    var accessibilityValue: String {
        if case .live = self { "live" } else { "notLive" }
    }
}

private struct PanelStatusLine: View {
    let status: PanelStatus

    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case let .live(text):
                Circle()
                    .fill(DS.Palette.accent)
                    .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                    .accessibilityHidden(true)
                Text(text).foregroundStyle(DS.Palette.text)
            case let .plain(text):
                Text(text).foregroundStyle(DS.Palette.secondary)
            case let .error(text):
                Text(text).foregroundStyle(DS.Palette.no)
            }
        }
        .font(DS.Font.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: status.accessibilityValue))
    }
}

/// 28 pt tile, white symbol on `accentFill` (outcome: `okFill`). No gradient, no shadow.
struct PanelIconTile: View {
    enum Style { case accent, ok }

    let symbol: String
    /// `symbolHeader` in live panels, prompt, outcome and popups; `symbolHomeHeader` for the command home `mic`.
    var symbolSize: CGFloat = DS.Size.symbolHeader
    var style: Style = .accent
    /// Translate meeting: a `globe` badge at the bottom-right corner.
    var hasGlobeBadge = false
    /// Outcome check: one 1 -> 1.15 -> 1 pulse when it appears (M8); none under Reduce Motion.
    var pulsesOnAppear = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulses = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: DS.Size.iconTile, height: DS.Size.iconTile)
            .background(
                style == .ok ? DS.Palette.okFill : DS.Palette.accentFill,
                in: RoundedRectangle(cornerRadius: DS.Radius.iconTile, style: .continuous)
            )
            .overlay(alignment: .bottomTrailing) {
                if hasGlobeBadge {
                    Image(systemName: "globe")
                        .font(.system(size: DS.Size.symbolBadge, weight: .medium))
                        .foregroundStyle(DS.Palette.accent)
                        .frame(width: DS.Size.badge, height: DS.Size.badge)
                        .background(DS.Palette.panel, in: Circle())
                        .offset(x: -DS.Size.badgeOffset, y: -DS.Size.badgeOffset)
                }
            }
            .keyframeAnimator(initialValue: 1.0, trigger: pulses) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(DS.Motion.pulseScale, duration: DS.Motion.m8SuccessPulse.duration / 2)
                    CubicKeyframe(1.0, duration: DS.Motion.m8SuccessPulse.duration / 2)
                }
            }
            .onAppear {
                if pulsesOnAppear && !reduceMotion { pulses += 1 }
            }
            .accessibilityHidden(true)
    }
}

/// 26 pt icon button on `chip`; glyph `secondary`, `text` on hover.
struct PanelIconButton: View {
    enum Kind { case minimize, close }

    let kind: Kind
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: kind == .minimize ? "minus" : "xmark")
                .font(.system(size: DS.Size.symbolIconButton, weight: .semibold))
                .foregroundStyle(isHovered ? DS.Palette.text : DS.Palette.secondary)
                .frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
                .background(DS.Palette.chip, in: RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(kind == .minimize ? Text("Hide recording panel") : Text("Close"))
    }
}

/// "06:22" in 11 pt tabular digits; the silence countdown uses `warn`.
struct PanelTimer: View {
    let text: String
    var isWarning = false

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.caption)
            .monospacedDigit()
            .foregroundStyle(isWarning ? DS.Palette.warn : DS.Palette.secondary)
    }
}
