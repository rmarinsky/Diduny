import SwiftUI

/// Translate meeting live content. STUB for WP-32 (design-spec 7.3): today's content in the new shell,
/// waveform circle and the 170 pt transcript. WP-32 replaces the body of this file.
struct TranslateMeetingLiveContent: View {
    let store: LiveDictationOverlayStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            LiveWaveformCircle(store: store)
            TranscriptBox(height: DS.Size.transcriptMeeting) {
                LiveTranscriptContent(store: store)
            }
        }
    }
}
