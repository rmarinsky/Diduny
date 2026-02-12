import SwiftUI

struct AudioPlaybackControlView: View {
    let recordingId: UUID
    let fileURL: URL
    var durationHint: TimeInterval = 0

    @State private var playbackService = AudioPlaybackService.shared

    private var isActiveRecording: Bool {
        playbackService.playingRecordingId == recordingId
    }

    private var effectiveDuration: TimeInterval {
        if isActiveRecording, playbackService.duration > 0 {
            return playbackService.duration
        }
        return max(durationHint, 0.01)
    }

    private var currentTime: TimeInterval {
        isActiveRecording ? playbackService.currentTime : 0
    }

    var body: some View {
        HStack(spacing: 8) {
            // Play/Pause button
            Button {
                playbackService.togglePlayback(recordingId: recordingId, fileURL: fileURL)
            } label: {
                Image(systemName: isActiveRecording && playbackService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            // Always-visible slider
            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { playbackService.seek(to: $0) }
                ),
                in: 0 ... effectiveDuration,
                onEditingChanged: { editing in
                    playbackService.isSeeking = editing
                }
            )

            // Time display: elapsed / total
            Text("\(formatTime(currentTime)) / \(formatTime(effectiveDuration))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
