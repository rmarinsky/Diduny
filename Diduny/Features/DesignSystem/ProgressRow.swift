import SwiftUI

/// 4 pt bar, track `chip`, fill `accent` from the leading edge (design-spec 4.15). The fill
/// moves linearly, 200 ms per update (M16), also under Reduce Motion: progress is information.
/// Accessibility sees a native progress indicator with `label`.
struct PanelProgressBar: View {
    /// 0...1.
    let fraction: Double
    /// The line the bar belongs to, for example "Saving the recording...".
    var label: LocalizedStringKey?

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.Palette.chip)
                RoundedRectangle(cornerRadius: DS.Radius.progressBar, style: .continuous)
                    .fill(DS.Palette.accent)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: DS.Size.progressBar)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.progressBar, style: .continuous))
        .animation(.linear(duration: DS.Motion.m16Progress.duration), value: fraction)
        .accessibilityRepresentation {
            ProgressView(value: clamped) {
                if let label { Text(label) }
            }
        }
    }
}

/// After Stop the controls row becomes this, in place (M3): the line, 6 above the bar,
/// vertically centred in 38.
struct ProgressRow: View {
    /// "Finishing the last words..." or "Saving the recording...".
    let line: LocalizedStringKey
    let fraction: Double
    /// For example `livePanel.progress` or `outcome.progress`: the bar gets it, the line
    /// `<prefix>.line`.
    var idPrefix: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.secondary)
                .lineLimit(1)
                .accessibilityIdentifier(ifPresent: idPrefix.map { "\($0).line" })
            PanelProgressBar(fraction: fraction, label: line)
                .accessibilityIdentifier(ifPresent: idPrefix)
        }
        .frame(maxWidth: .infinity, minHeight: DS.Size.panelButton, maxHeight: DS.Size.panelButton)
    }
}
