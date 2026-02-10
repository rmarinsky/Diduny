import SwiftUI

struct RecordingRowView: View {
    let recording: Recording

    private let storage = RecordingsLibraryStorage.shared

    var body: some View {
        HStack(spacing: 10) {
            // Type icon
            Image(systemName: recording.type.iconName)
                .foregroundColor(iconColor)
                .font(.title3)
                .frame(width: 24)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text("\(recording.type.displayName) - \(formattedDate)")
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(formattedSize)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    statusBadge
                }
            }

            // Playback control
            AudioPlaybackControlView(
                recordingId: recording.id,
                fileURL: storage.audioFileURL(for: recording)
            )

            Spacer()

            // Transcription preview
            if let text = recording.transcriptionText, !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch recording.type {
        case .voice: .blue
        case .translation: .green
        case .meeting: .orange
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: recording.createdAt)
    }

    private var formattedDuration: String {
        let minutes = Int(recording.durationSeconds) / 60
        let seconds = Int(recording.durationSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: recording.fileSizeBytes, countStyle: .file)
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(recording.status.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(statusColor.opacity(0.15))
            .foregroundColor(statusColor)
            .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch recording.status {
        case .unprocessed: .gray
        case .processing: .blue
        case .transcribed: .green
        case .translated: .purple
        case .failed: .red
        }
    }
}
