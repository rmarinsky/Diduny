import SwiftUI

struct RecordingRowView: View {
    let recording: Recording
    let onOpen: () -> Void
    let onTranscribe: () -> Void
    let onDelete: () -> Void
    var onProcessRecovery: (() -> Void)?
    var onSaveRecoveryAudio: (() -> Void)?
    var isSelectionMode = false
    var isSelected = false
    var onToggleSelection: (() -> Void)?

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
                if recording.recoverySource != nil {
                    recoveredBadge
                }
                if recording.status == .needsRecovery {
                    needsProcessingBadge
                }
                if recording.status == .recording {
                    recordingBadge
                }
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
        let canPlay = RecordingsLibraryStorage.shared.hasPlayableAudio(for: recording)
        let label = isPlaying ? "Pause recording" : "Play recording"
        return Button {
            guard canPlay else { return }
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
                        .foregroundColor(canPlay ? Color("BrandAccentDeep") : .secondary)
                        .offset(x: isPlaying ? 0 : 1)
                }
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .help(canPlay ? label : "Audio not ready yet")
        .accessibilityLabel(Text(canPlay ? label : "Audio not ready yet"))
        .accessibilityIdentifier(label)
    }

    private var typeBadge: some View {
        Text(recording.libraryDisplayName)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(recording.libraryBrandColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(recording.libraryBrandColor.opacity(0.12), in: Capsule())
    }

    private var recoveredBadge: some View {
        Text("Recovered")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
    }

    private var needsProcessingBadge: some View {
        Text("Needs processing")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.red)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12), in: Capsule())
    }

    private var recordingBadge: some View {
        Text("Recording")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.green)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.12), in: Capsule())
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if recording.status == .needsRecovery {
                if let onProcessRecovery {
                    RecordingActionButton(
                        systemName: "arrow.triangle.2.circlepath",
                        label: "Process recovery",
                        action: onProcessRecovery
                    )
                }
                if let onSaveRecoveryAudio {
                    RecordingActionButton(
                        systemName: "square.and.arrow.down",
                        label: "Save audio only",
                        action: onSaveRecoveryAudio
                    )
                }
            } else if recording.status != .processing, recording.status != .recording {
                RecordingActionButton(
                    systemName: "text.bubble",
                    label: "Transcribe recording",
                    action: onTranscribe
                )
                if let primary = recording.resolvedTranscriptHistory.first {
                    TranscriptSpeakButton(
                        versionId: primary.id,
                        text: primary.text,
                        languageCode: primary.targetLanguageCode ?? primary.sourceLanguageCode,
                        compact: true
                    )
                }
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
        let start = formatter.string(from: recording.createdAt)
        let timeRange: String = if recording.status == .recording {
            "\(start)–…"
        } else if let ended = recording.resolvedEndedAt {
            "\(start)–\(formatter.string(from: ended))"
        } else {
            start
        }
        switch recording.type {
        case .voice: return "Voice note — \(timeRange)"
        case .translation: return "Translation — \(timeRange)"
        case .meeting: return "Meeting — \(timeRange)"
        case .meetingTranslation: return "Meeting translation — \(timeRange)"
        case .fileTranscription: return recording.sourceFileName ?? "File — \(timeRange)"
        }
    }

    private var previewText: String {
        if recording.status == .recording {
            return recording.statusDetail ?? "Recording…"
        }
        if recording.status == .needsRecovery {
            return "Needs processing — recover audio from this session"
        }
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
