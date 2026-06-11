import SwiftUI

struct RecordingRowView: View {
    let recording: Recording

    @State private var playbackService = AudioPlaybackService.shared

    private var isPlaying: Bool {
        playbackService.playingRecordingId == recording.id && playbackService.isPlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            playButton

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rowTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    typeBadge
                }
                if let preview = previewText {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedDuration)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                Text(relativeDay)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Subviews

    private var playButton: some View {
        Button {
            playbackService.togglePlayback(
                recordingId: recording.id,
                fileURL: RecordingsLibraryStorage.shared.audioFileURL(for: recording)
            )
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.quaternaryLabelColor).opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color("BrandAccentDeep"))
                    .offset(x: isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var typeBadge: some View {
        Text(recording.type.displayName)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(recording.type.brandColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(recording.type.brandColor.opacity(0.12), in: Capsule())
    }

    // MARK: - Computed

    private var rowTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: recording.createdAt)
        switch recording.type {
        case .voice: return "Voice note — \(time)"
        case .translation: return "Translation — \(time)"
        case .meeting: return "Meeting — \(time)"
        case .fileTranscription: return "File — \(time)"
        }
    }

    private var previewText: String? {
        guard let text = recording.transcriptionText, !text.isEmpty else { return nil }
        return text
    }

    private var formattedDuration: String {
        let total = Int(recording.durationSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private var relativeDay: String {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(recording.createdAt) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "Today, \(f.string(from: recording.createdAt))"
        }
        if cal.isDateInYesterday(recording.createdAt) { return "Yesterday" }
        let daysAgo = cal.dateComponents([.day], from: recording.createdAt, to: now).day ?? 0
        if daysAgo < 7 {
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: recording.createdAt)
        }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: recording.createdAt)
    }
}
