import AppKit
import SwiftUI

/// Translate meeting rows of the live panel (design-spec 7.3): WP-32's `TranslateMeetingPanelContent`
/// fed from the store.
struct TranslateMeetingLiveContent: View {
    @Bindable var store: LiveDictationOverlayStore

    var body: some View {
        if let model = store.translateMeetingPanelModel {
            TranslateMeetingPanelContent(
                model: model,
                turns: store.meetingTranslation.turns,
                showsOriginal: $store.meetingTranslationShowsOriginal,
                onPickPair: store.pickMeetingTranslationPair,
                onPickEngine: { store.meetingTranslationEngine = $0 },
                onOpenLanguages: { (NSApp.delegate as? AppDelegate)?.openSettings(tab: .languages) }
            ) {
                LiveWaveformCircle(store: store)
                    .frame(width: DS.Size.waveformCircle, height: DS.Size.waveformCircle)
                    .accessibilityIdentifier("livePanel.waveform")
            }
        }
    }
}

/// Meeting rows of the live panel: WP-31's `MeetingLiveContent` fed from the store.
struct MeetingLiveSection: View {
    @Bindable var store: LiveDictationOverlayStore

    var body: some View {
        MeetingLiveContent(
            state: store.meetingPanelState,
            lines: store.meetingLines,
            segment: $store.meetingSegment,
            onPickEngine: { store.meetingEngines[store.meetingSegment] = $0 },
            onDownloadParakeet: { ParakeetModelController.shared.download() }
        ) {
            LiveWaveformCircle(store: store)
        }
    }
}
