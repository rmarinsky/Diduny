import SwiftUI

/// Dictation and dictation translation (design-spec 7.2, 01 §4): waveform circle and the Output +
/// Engine pair, the caption line, then a 120 pt transcript or calm box.
struct DictationLiveContent: View {
    let store: LiveDictationOverlayStore
    let onSelectOutput: (DictationOutput) -> Void

    var body: some View {
        let state = store.panelState
        VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            HStack(spacing: 10) {
                LiveWaveformCircle(store: store)
                LivePairLayout {
                    outputField
                    engineField
                }
            }
            if let caption = state.caption {
                captionLine(caption)
            }
            switch state.body {
            case .transcript:
                TranscriptBox(height: DS.Size.transcriptDictation) {
                    LiveTranscriptContent(store: store)
                }
            case let .calm(title, detail):
                CalmBox(title: LocalizedStringKey(title), detail: LocalizedStringKey(detail), height: DS.Size.transcriptDictation)
            }
        }
    }

    /// Interactive while the caller offers switching (`outputOptions`), else it states the output.
    @ViewBuilder
    private var outputField: some View {
        if !store.outputOptions.isEmpty, store.canStop {
            PickerField(
                label: "Output",
                value: store.selectedOutput.label,
                layout: .stackedInPair,
                identifier: "livePanel.output",
                menu: { store.outputMenu },
                onPick: { id in
                    if let output = DictationOutputMenu.output(forRowID: id) { onSelectOutput(output) }
                }
            )
        } else {
            PickerField(staticLabel: "Output", value: outputLabel, layout: .stackedInPair, identifier: "livePanel.output")
        }
    }

    private var outputLabel: String {
        if store.outputOptions.isEmpty, case let .translation(target) = store.mode {
            return DictationOutput.translation(targetLanguage: target).label
        }
        return store.selectedOutput.label
    }

    /// Static until the engine can change during a recording (WP-64).
    private var engineField: some View {
        PickerField(
            staticLabel: "Engine",
            value: store.sessionEngine?.name ?? "",
            layout: .stackedInPair,
            identifier: "livePanel.engine"
        )
    }

    /// The caption, and "Set by voice · Undo" after a spoken command (01 Q18 default).
    private func captionLine(_ caption: String) -> some View {
        HStack(spacing: DS.Space.sm) {
            LivePanelCaption(text: caption)
            if store.voiceCommand != nil {
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("Set by voice ·").foregroundStyle(DS.Palette.secondary)
                    InlineLink(title: "Undo") { onSelectOutput(store.pickedOutput) }
                        .help("Keep the original output; the command words stay in the text.")
                }
                .font(DS.Font.meta)
                .fixedSize()
            }
        }
    }
}

/// Two stacked fields side by side, 0.95 : 1.05, 6 apart (design-spec 3.4 `.pair`).
struct LivePairLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let widths = widths(proposal.width ?? 226)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 226, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + 6
        }
    }

    private func widths(_ total: CGFloat) -> [CGFloat] {
        PanelControlsLayout.widths(available: total, weights: [0.95, 1.05], spacing: 6)
    }
}
