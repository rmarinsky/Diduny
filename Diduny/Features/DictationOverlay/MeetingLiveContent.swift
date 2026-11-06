import SwiftUI

/// Meeting live content. STUB for WP-31 (design-spec 7.1): today's content in the new shell, so meetings
/// keep working: waveform circle, then the 170 pt transcript, or the record-only box with
/// "Turn on live transcript". WP-31 replaces the body of this file.
struct MeetingLiveContent: View {
    let store: LiveDictationOverlayStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            LiveWaveformCircle(store: store)
            if let turnOn = store.onTurnOnLiveTranscript, !store.hasText, store.canStop {
                recordingOnly(turnOn)
            } else {
                TranscriptBox(height: DS.Size.transcriptMeeting) {
                    LiveTranscriptContent(store: store)
                }
            }
        }
    }

    private func recordingOnly(_ turnOn: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text("Recording only. The transcript will be ready after the meeting, made on this Mac.")
                .font(DS.Font.content)
                .foregroundStyle(DS.Palette.secondary)
            Button("Turn on live transcript", action: turnOn)
                .buttonStyle(.borderedProminent)
                .tint(DS.Palette.accentFill)
            Text("Live view from now, in the cloud. The final transcript is still made on this Mac.")
                .font(DS.Font.fieldLabel)
                .foregroundStyle(DS.Palette.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity)
        .frame(height: DS.Size.transcriptMeeting)
        .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.box, style: .continuous))
    }
}
