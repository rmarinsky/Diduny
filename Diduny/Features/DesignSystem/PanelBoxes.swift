import SwiftUI

extension DS.Size {
    /// Transcript and calm box height in meeting panels (D9).
    static let transcriptMeeting: CGFloat = 170
    /// Transcript and calm box height in dictation panels (D9).
    static let transcriptDictation: CGFloat = 120
    /// The result box grows with its text up to this, then scrolls.
    static let resultMaxHeight: CGFloat = 170
}

/// Live transcript (design-spec 4.18): `box` fill, radius 8, padding 10, 12.5 `text` at line
/// height 18.1, paragraphs 6 apart, fixed height, content kept at the bottom as it grows.
struct TranscriptBox<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) { content() }
                .font(DS.Font.content)
                .foregroundStyle(DS.Palette.text)
                .lineSpacing(DS.Font.LineSpacing.content)
                .frame(maxWidth: .infinity, minHeight: height - 20, alignment: .bottomLeading)
                .padding(10)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: height)
        .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.box, style: .continuous))
        .accessibilityIdentifier("livePanel.transcript")
    }
}

/// No live text (4.18): same size and fill as the transcript, a centred title (13 `text`) and
/// detail (11.5 `secondary`, at most 230 wide), 6 apart, padding 16.
struct CalmBox: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let height: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.text)
                .accessibilityIdentifier("livePanel.calm.title")
            Text(detail)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.secondary)
                .frame(maxWidth: 230)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("livePanel.calm.detail")
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.box, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("livePanel.calm")
    }
}

/// Outcome result text (4.18): `box`, radius 8, padding 10, 12.5 at 18.1; as tall as the text
/// up to 170, then it scrolls.
struct ResultBox: View {
    let text: String

    var body: some View {
        CappedHeightLayout(maxHeight: DS.Size.resultMaxHeight) {
            ScrollView(.vertical) {
                Text(verbatim: text)
                    .font(DS.Font.content)
                    .foregroundStyle(DS.Palette.text)
                    .lineSpacing(DS.Font.LineSpacing.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.box, style: .continuous))
        .accessibilityIdentifier("outcome.result")
    }
}

/// Takes its one child's height for the proposed width, capped at `maxHeight`.
private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
