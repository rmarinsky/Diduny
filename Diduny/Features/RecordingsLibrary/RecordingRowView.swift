import SwiftUI

struct RecordingRowView: View {
    let recording: Recording
    let onOpen: () -> Void
    let onTranscribe: () -> Void
    let onDelete: () -> Void
    var isSelectionMode = false
    var isSelected = false
    var onToggleSelection: (() -> Void)? = nil

    @State private var playbackService = AudioPlaybackService.shared

    private var isPlaying: Bool {
        playbackService.playingRecordingId == recording.id && playbackService.isPlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                selectionButton
            }

            playButton

            Button(action: onOpen) {
                rowContent
            }
            .buttonStyle(.plain)

            if !isSelectionMode {
                actionButtons
            }

            Spacer(minLength: 8)

            metaColumn
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    // MARK: - Subviews

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(rowTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                typeBadge
                if recording.status == .processing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
            }
            Text(previewText)
                .font(.system(size: 12))
                .foregroundColor(previewColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var selectionButton: some View {
        Button {
            onToggleSelection?()
        } label: {
            Label {
                Text(isSelected ? "Deselect recording" : "Select recording")
            } icon: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isSelected ? Color("BrandAccentDeep") : .secondary)
                    .frame(width: 24, height: 24)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Deselect recording" : "Select recording")
        .accessibilityLabel(Text(isSelected ? "Deselect recording" : "Select recording"))
        .accessibilityIdentifier(isSelected ? "Recording selected" : "Recording not selected")
    }

    private var playButton: some View {
        let label = isPlaying ? "Pause recording" : "Play recording"
        return Button {
            playbackService.togglePlayback(
                recordingId: recording.id,
                fileURL: RecordingsLibraryStorage.shared.audioFileURL(for: recording)
            )
        } label: {
            Label {
                Text(label)
            } icon: {
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
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(label)
    }

    private var typeBadge: some View {
        Text(recording.type.displayName)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(recording.type.brandColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(recording.type.brandColor.opacity(0.12), in: Capsule())
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if recording.status != .processing {
                RecordingActionButton(
                    systemName: "text.bubble",
                    label: "Transcribe recording",
                    action: onTranscribe
                )
            }

            RecordingActionButton(
                systemName: "trash",
                label: "Delete recording",
                isDestructive: true,
                action: onDelete
            )
        }
    }

    private var metaColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(formattedDuration)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
            Text(relativeDay)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(width: 76, alignment: .trailing)
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
        case .meetingTranslation: return "Meeting translation — \(time)"
        case .fileTranscription: return "File — \(time)"
        }
    }

    private var previewText: String {
        if recording.status == .processing {
            return "Transcribing..."
        }
        if recording.status == .failed {
            return recording.errorMessage ?? "Transcription failed"
        }
        if let text = recording.transcriptionText, !text.isEmpty {
            return text
        }
        return "No transcription yet"
    }

    private var previewColor: Color {
        recording.status == .failed ? .red : .secondary
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

private struct RecordingActionButton: View {
    let systemName: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    private var tint: Color {
        isDestructive ? .red : Color("BrandAccentDeep")
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 28, height: 28)
                    .background(Color(.quaternaryLabelColor).opacity(0.10), in: Circle())
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(label)
    }
}
