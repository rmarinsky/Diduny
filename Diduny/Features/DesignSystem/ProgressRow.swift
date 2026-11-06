import SwiftUI

/// 4 pt bar, track `chip`, fill `accent` from the leading edge (design-spec 4.15). The fill
/// moves linearly, 200 ms per update (M16), also under Reduce Motion: progress is information.
struct PanelProgressBar: View {
    /// 0...1.
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(DS.Palette.chip)
                RoundedRectangle(cornerRadius: DS.Radius.progressBar, style: .continuous)
                    .fill(DS.Palette.accent)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: DS.Size.progressBar)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.progressBar, style: .continuous))
        .animation(.linear(duration: DS.Motion.m16Progress.duration), value: fraction)
    }
}

/// After Stop the controls row becomes this, in place (M3): the line, 6 above the bar,
/// vertically centred in 38.
struct ProgressRow: View {
    /// "Finishing the last words..." or "Saving the recording...".
    let line: LocalizedStringKey
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("livePanel.progress.line")
            PanelProgressBar(fraction: fraction)
                .accessibilityElement()
                .accessibilityLabel(Text(line))
                .accessibilityValue(Text(min(max(fraction, 0), 1), format: .percent.precision(.fractionLength(0))))
                .accessibilityIdentifier("livePanel.progress")
        }
        .frame(maxWidth: .infinity, minHeight: DS.Size.panelButton, maxHeight: DS.Size.panelButton)
    }
}
