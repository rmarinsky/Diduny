import SwiftUI

struct RecordingRowView: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 8) {
            // Type prefix badge
            Text(recording.type.shortPrefix)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(typeColor.opacity(0.15))
                .foregroundColor(typeColor)
                .clipShape(Capsule())

            // Time only (date is shown in section header)
            Text(formattedTime)
                .font(.body)
                .lineLimit(1)

            Text("\u{00B7}")
                .foregroundColor(.secondary)

            // Duration
            Text(formattedDuration)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("\u{00B7}")
                .foregroundColor(.secondary)

            // Size
            Text(formattedSize)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var typeColor: Color {
        switch recording.type {
        case .voice: .blue
        case .translation: .green
        case .meeting: .orange
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
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
}
