import SwiftUI

/// Outcome content after Stop (design-spec 4.16, 7.7; `cmdDone` P:626-638). The panel frame
/// (width 300, padding 12, fill, border) and the M1 slide come from the command panel shell.
/// Dictation 300 x 169 with a one-line result, meeting 300 x 117.
struct EdgeCommandOutcomeView: View {
    let outcome: EdgeCommandOutcome
    /// Meetings only; dictation ignores it.
    var transcript: OutcomeTranscriptState = .ready
    var isCopied = false
    var onClose: () -> Void = {}
    var onCopy: () -> Void = {}
    var onNewRecording: () -> Void = {}
    var onOpenRecording: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { // panel block gap (design-spec 3.4)
            PanelHeader(
                icon: PanelIconTile(symbol: "checkmark", style: .ok, pulsesOnAppear: true),
                title: LocalizedStringKey(outcome.title),
                status: .plain(LocalizedStringKey(outcome.subtitle(transcript: transcript))),
                titleID: "outcome.title",
                statusID: "outcome.subtitle"
            ) {
                PanelIconButton(kind: .close, action: onClose)
                    .accessibilityIdentifier("outcome.close")
            }
            // The check pulse (M8) restarts for each new outcome, not for subtitle changes.
            .id(outcome.id)

            if outcome.flow.isMeeting {
                PanelProgressBar(fraction: progressFraction, label: LocalizedStringKey(outcome.subtitle(transcript: transcript)))
                    .accessibilityIdentifier("outcome.progress")
                PanelControlsLayout(weights: [1, 1]) {
                    PanelButton(title: "Open recording", role: .primary, action: onOpenRecording)
                        .disabled(outcome.recordingID == nil)
                        .accessibilityIdentifier("outcome.openRecording")
                    newRecordingButton
                }
            } else {
                ResultBox(text: outcome.resultText)
                PanelControlsLayout(weights: [1, 1]) {
                    CopyButton(isCopied: isCopied, action: onCopy)
                        .accessibilityIdentifier("outcome.copy")
                    newRecordingButton
                }
            }
        }
    }

    private var newRecordingButton: some View {
        PanelButton(title: "New recording", action: onNewRecording)
            .accessibilityIdentifier("outcome.newRecording")
    }

    private var progressFraction: Double {
        switch transcript {
        case let .making(fraction): fraction
        case .ready: 1
        }
    }
}

#Preview("Dictation") {
    EdgeCommandOutcomeView(outcome: EdgeCommandOutcome(
        flow: .dictation, durationSeconds: 7, delivery: .pasted,
        resultText: "Yes, by the way, I want to refresh the window view now."
    ))
    .padding(12).frame(width: 300).background(DS.Palette.panel)
}

#Preview("Meeting") {
    EdgeCommandOutcomeView(
        outcome: EdgeCommandOutcome(flow: .meetingTranslation(pair: "EN ↔ UK"), durationSeconds: 382, recordingID: UUID()),
        transcript: .making(fraction: 0.4)
    )
    .padding(12).frame(width: 300).background(DS.Palette.panel)
}
