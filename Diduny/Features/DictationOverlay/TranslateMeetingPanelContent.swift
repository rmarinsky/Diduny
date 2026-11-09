import SwiftUI

/// Translate meeting live panel body (design-spec 7.3, 12.3): the waveform row with "Between" and
/// "Engine", the caption line with "Show original text", then the transcript or the calm box.
/// The shell (WP-30) draws the header, the controls and passes the waveform circle in.
struct TranslateMeetingPanelContent<Waveform: View>: View {
    let model: TranslateMeetingPanelModel
    let turns: [TranslateMeetingTurn]
    @Binding var showsOriginal: Bool
    /// A pair picked for this meeting only (decision 14 DEFAULT).
    let onPickPair: (TranslationLanguagePair) -> Void
    let onPickEngine: (EngineID) -> Void
    /// Panel-only lines where a switch or a pair change happened.
    var markers: [MeetingSwitchMarker] = []
    var switchLine: MeetingSwitchText.Line?
    var onFailureAction: () -> Void = {}
    /// "Other languages..." opens Settings > Languages.
    let onOpenLanguages: () -> Void
    @ViewBuilder var waveform: () -> Waveform

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm + 2) {
            HStack(spacing: DS.Space.sm + 2) {
                waveform()
                fields
            }
            captionLine
            if let switchLine {
                WarningLine(
                    message: switchLine.message, linkTitle: switchLine.linkTitle,
                    action: onFailureAction, id: "livePanel.switchLine", linkID: "livePanel.switchLineAction"
                )
            }
            if model.isLive {
                transcript
            } else {
                CalmBox(title: "Recording", detail: "\(turns.isEmpty ? model.calmDetail ?? "" : MeetingSwitchText.translateCalmWithText(pair: model.pair, locale: model.locale))", height: Self.boxHeight)
            }
        }
    }

    static var boxHeight: CGFloat { 170 }

    /// `.pair` P:76: columns 0.95 : 1.05, gap 6.
    private var fields: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 6
            let width = max(proxy.size.width - gap, 0)
            HStack(spacing: gap) {
                PickerField(
                    label: "Between", value: model.pair.shortLabel, layout: .stackedInPair,
                    identifier: "livePanel.between",
                    menu: { model.betweenMenu },
                    onPick: { id in
                        if id == TranslateMeetingPanelModel.RowID.otherLanguages {
                            onOpenLanguages()
                        } else if let pair = model.pair(forRowID: id) {
                            onPickPair(pair)
                        }
                    }
                )
                .frame(width: width * 0.475)
                Group {
                    if model.engines.count <= 1 {
                        PickerField(staticLabel: "Engine", value: model.engine.name, layout: .stackedInPair, identifier: "livePanel.engine")
                    } else {
                        PickerField(
                            label: "Engine", value: model.engine.name, layout: .stackedInPair, menuAlignment: .trailing,
                            identifier: "livePanel.engine",
                            menu: { model.engineMenu },
                            onPick: { id in EngineID(rawValue: id).map(onPickEngine) }
                        )
                    }
                }
                .frame(width: width * 0.525)
            }
        }
        .frame(height: DS.Field.stackedVerticalPadding * 2 + DS.Field.stackedLabelRowHeight + DS.Field.stackedValueRowHeight)
    }

    private var captionLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Text(verbatim: model.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("livePanel.caption")
            Spacer(minLength: 0)
            if model.showsOriginalLink {
                InlineLink(title: showsOriginal ? "Hide original text" : "Show original text") {
                    if reduceMotion {
                        showsOriginal.toggle()
                    } else {
                        withAnimation(DS.Motion.easeOut(0.15)) { showsOriginal.toggle() }
                    }
                }
                .accessibilityIdentifier("livePanel.showOriginal")
            }
        }
        .font(DS.Font.meta)
        .foregroundStyle(DS.Palette.secondary)
        .lineSpacing(DS.Font.LineSpacing.meta)
    }

    private var transcript: some View {
        TranscriptBox(height: Self.boxHeight) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                markerLines(afterTurn: index)
                VStack(alignment: .leading, spacing: 0) {
                    if let label = turn.label {
                        Text(verbatim: label)
                            .font(DS.Font.captionStrong)
                            .foregroundStyle(DS.Palette.accentText)
                            .padding(.bottom, 1)
                            .accessibilityIdentifier("livePanel.speakerLine")
                    }
                    if showsOriginal, !turn.original.isEmpty {
                        Text(verbatim: turn.original.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Palette.secondary)
                            .padding(.bottom, 2)
                            .transition(.opacity)
                            .accessibilityIdentifier("livePanel.originalLine")
                    }
                    if !turn.translation.isEmpty {
                        Text(verbatim: turn.translation.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                .padding(.top, turn.label == nil ? 0 : 6)
                .textSelection(.enabled)
            }
            ForEach(markers.indices.filter { markers[$0].afterTurnCount >= turns.count }, id: \.self) { markerLine(markers[$0]) }
        }
    }

    @ViewBuilder private func markerLines(afterTurn index: Int) -> some View {
        ForEach(markers.indices.filter { markers[$0].afterTurnCount == index && index < turns.count }, id: \.self) { markerLine(markers[$0]) }
    }

    private func markerLine(_ marker: MeetingSwitchMarker) -> some View {
        Text(verbatim: MeetingSwitchText.marker(marker, translateMeeting: true))
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.secondary)
            .accessibilityIdentifier("livePanel.marker")
    }
}
