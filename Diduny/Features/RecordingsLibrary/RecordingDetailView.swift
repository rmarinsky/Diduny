import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording

    @State private var playbackService = AudioPlaybackService.shared
    @State private var queueService = RecordingQueueService.shared
    @State private var modelManager = WhisperModelManager.shared
    @State private var selectedModelChoice: ModelChoice = .soniox

    private let storage = RecordingsLibraryStorage.shared

    enum ModelChoice: Hashable {
        case soniox
        case whisper(modelName: String)

        var displayName: String {
            switch self {
            case .soniox:
                "Soniox (Cloud)"
            case .whisper(let modelName):
                WhisperModelManager.availableModels
                    .first(where: { $0.name == modelName })?.displayName ?? modelName
            }
        }
    }

    private var downloadedWhisperModels: [WhisperModelManager.WhisperModel] {
        WhisperModelManager.availableModels.filter { modelManager.isModelDownloaded($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header
                .padding(12)

            Divider()

            // Playback
            playbackSection
                .padding(12)

            Divider()

            // Transcription text
            transcriptionSection

            Divider()

            // Model picker + actions
            actionsSection
                .padding(12)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: recording.type.iconName)
                .font(.title2)
                .foregroundColor(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.type.displayName)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(formattedSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            statusBadge
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        AudioPlaybackControlView(
            recordingId: recording.id,
            fileURL: storage.audioFileURL(for: recording)
        )
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        ScrollView {
            Group {
                if recording.status == .processing {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Processing...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let text = recording.transcriptionText, !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No transcription yet")
                        .foregroundColor(.secondary)
                        .italic()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Model picker
            HStack {
                Text("Model:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $selectedModelChoice) {
                    Text("Soniox (Cloud)").tag(ModelChoice.soniox)

                    if !downloadedWhisperModels.isEmpty {
                        Divider()
                        ForEach(downloadedWhisperModels) { model in
                            Text("Whisper: \(model.displayName)")
                                .tag(ModelChoice.whisper(modelName: model.name))
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 250)
                .labelsHidden()
            }

            // Action buttons
            HStack(spacing: 8) {
                Button("Transcribe") {
                    let (provider, whisperModel) = resolveOverrides()
                    queueService.enqueue(
                        [recording.id],
                        action: .transcribe,
                        providerOverride: provider,
                        whisperModelOverride: whisperModel
                    )
                }
                .disabled(recording.status == .processing)

                Button("Translate") {
                    let (provider, whisperModel) = resolveOverrides()
                    queueService.enqueue(
                        [recording.id],
                        action: .translate,
                        providerOverride: provider,
                        whisperModelOverride: whisperModel
                    )
                }
                .disabled(recording.status == .processing)

                if let text = recording.transcriptionText, !text.isEmpty {
                    Button("Copy Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func resolveOverrides() -> (TranscriptionProvider, String?) {
        switch selectedModelChoice {
        case .soniox:
            return (.soniox, nil)
        case .whisper(let modelName):
            return (.whisperLocal, modelName)
        }
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
