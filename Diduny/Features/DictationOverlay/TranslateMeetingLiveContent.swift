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
                onPickEngine: store.pickMeetingTranslationEngine,
                markers: store.meetingSwitch.markers,
                switchLine: store.meetingSwitchLine,
                onFailureAction: store.runMeetingFailureAction,
                // SwiftUI's `NSApp.delegate` is an adaptor, not `AppDelegate`.
                onOpenLanguages: { AppDelegate.current?.openSettings(tab: .languages) }
            ) {
                LiveWaveformCircle(store: store)
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
            segment: Binding(get: { store.meetingSegment }, set: { store.pickMeetingSegment($0) }),
            onPickEngine: store.pickMeetingEngine,
            onDownloadParakeet: { ParakeetModelController.shared.download() },
            switchLine: store.meetingSwitchLine,
            onFailureAction: store.runMeetingFailureAction
        ) {
            LiveWaveformCircle(store: store)
        }
    }
}
