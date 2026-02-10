import SwiftUI

struct AudioPlaybackControlView: View {
    let recordingId: UUID
    let fileURL: URL

    @State private var playbackService = AudioPlaybackService.shared

    private var isActiveRecording: Bool {
        playbackService.playingRecordingId == recordingId
    }

    var body: some View {
        HStack(spacing: 6) {
            // Play/Pause button
            Button {
                playbackService.togglePlayback(recordingId: recordingId, fileURL: fileURL)
            } label: {
                Image(systemName: isActiveRecording && playbackService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)

            // Slider + time (only when this is the active recording)
            if isActiveRecording {
                Slider(
                    value: Binding(
                        get: { playbackService.currentTime },
                        set: { playbackService.seek(to: $0) }
                    ),
                    in: 0 ... max(playbackService.duration, 0.01),
                    onEditingChanged: { editing in
                        playbackService.isSeeking = editing
                    }
                )
                .frame(minWidth: 60, maxWidth: 120)

                Text(formatTime(playbackService.currentTime))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
