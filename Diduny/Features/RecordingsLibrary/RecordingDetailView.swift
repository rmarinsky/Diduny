import SwiftUI

struct RecordingDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let recording: Recording

    @State private var playbackService = AudioPlaybackService.shared
    @State private var queueService = RecordingQueueService.shared
    @State private var modelManager = WhisperModelManager.shared
    @State private var selectedWhisperModel: String = SettingsStorage.shared.selectedWhisperModel
    @State private var storage = RecordingsLibraryStorage.shared

    private var currentRecording: Recording {
        storage.recordings.first(where: { $0.id == recording.id }) ?? recording
    }

    private var downloadedWhisperModels: [WhisperModelManager.WhisperModel] {
        WhisperModelManager.availableModels.filter { modelManager.isModelDownloaded($0) }
    }

    private var favoriteLanguages: [SupportedLanguage] {
        let codes = SettingsStorage.shared.favoriteLanguages
        return codes.compactMap { SupportedLanguage.language(for: $0) }
    }

    private var otherLanguages: [SupportedLanguage] {
        let favCodes = Set(SettingsStorage.shared.favoriteLanguages)
        return SupportedLanguage.allLanguages.filter { !favCodes.contains($0.code) }
    }

    private var queueStatusText: String? {
        guard queueService.currentRecordingId == currentRecording.id,
              let status = queueService.currentJobStatus
        else { return nil }

        switch status {
        case .queued:
            return "Queued..."
        case .uploading:
            return "Uploading..."
        case .processing:
            return "Transcribing..."
        case .finalizing:
            return "Finalizing..."
        case .completed, .error:
            return nil
        }
    }

    private var supportsSpeakerLabels: Bool {
        currentRecording.type.isMeetingLike
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

            // Actions
            actionsSection
                .padding(12)
        }
        .onExitCommand {
            dismiss()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: currentRecording.type.iconName)
                .font(.title2)
                .foregroundColor(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(currentRecording.type.displayName)
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

                if let sourceDevice = currentRecording.sourceDevice {
                    Text(deviceSummary(sourceDevice))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Text("Esc")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(.quaternaryLabelColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                .accessibilityIdentifier("Close recording detail")
            }
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        AudioPlaybackControlView(
            recordingId: currentRecording.id,
            fileURL: storage.audioFileURL(for: currentRecording),
            durationHint: currentRecording.durationSeconds
        )
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        ScrollView {
            Group {
                if currentRecording.status == .processing {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(queueStatusText ?? "Processing...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let text = currentRecording.transcriptionText, !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if currentRecording.status == .failed {
                    Text(currentRecording.errorMessage ?? "Transcription failed")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(alignment: .leading, spacing: 12) {
            // Cloud section
            cloudActionsSection

            Divider()

            // Local (Whisper) section
            localActionsSection

            // Copy text button
            if let text = currentRecording.transcriptionText, !text.isEmpty {
                Divider()
                HStack {
                    Spacer()
                    Button("Copy Text") {
                        ClipboardService.shared.copy(text: text, behavior: currentRecording.type.clipboardCopyBehavior)
                    }
                }
            }
        }
    }

    // MARK: - Cloud Actions

    private var cloudActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Cloud", systemImage: "cloud.fill")
                .font(.caption)
                .foregroundColor(Color("BrandAccentDeep"))

            VStack(alignment: .leading, spacing: 6) {
                Button("Transcribe") {
                    queueService.enqueue(
                        [currentRecording.id],
                        action: .transcribe,
                        providerOverride: .cloud
                    )
                }
                .disabled(currentRecording.status == .processing)

                if supportsSpeakerLabels {
                    Button("Transcribe with Speakers") {
                        queueService.enqueue(
                            [currentRecording.id],
                            action: .transcribeDiarize,
                            providerOverride: .cloud
                        )
                    }
                    .disabled(currentRecording.status == .processing)
                }

                HStack(spacing: 6) {
                    Text("Translate:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(favoriteLanguages) { lang in
                                Button(lang.code.uppercased()) {
                                    queueService.enqueue(
                                        [currentRecording.id],
                                        action: .translate,
                                        providerOverride: .cloud,
                                        targetLanguage: lang.code
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(currentRecording.status == .processing)
                                .help(lang.name)
                            }

                            if !otherLanguages.isEmpty {
                                Menu("...") {
                                    ForEach(otherLanguages) { lang in
                                        Button(lang.name) {
                                            queueService.enqueue(
                                                [currentRecording.id],
                                                action: .translate,
                                                providerOverride: .cloud,
                                                targetLanguage: lang.code
                                            )
                                        }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .controlSize(.small)
                                .disabled(currentRecording.status == .processing)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Local Actions

    private var localActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local (Whisper.cpp)", systemImage: "desktopcomputer")
                .font(.caption)
                .foregroundColor(.green)

            if !downloadedWhisperModels.isEmpty {
                HStack(spacing: 8) {
                    Picker("Model:", selection: $selectedWhisperModel) {
                        ForEach(downloadedWhisperModels) { model in
                            Text(model.displayName).tag(model.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)

                    Button("Transcribe Locally") {
                        let modelName = selectedWhisperModel.isEmpty ? downloadedWhisperModels.first?
                            .name : selectedWhisperModel
                        queueService.enqueue(
                            [currentRecording.id],
                            action: .transcribe,
                            providerOverride: .local,
                            whisperModelOverride: modelName
                        )
                    }
                    .disabled(currentRecording.status == .processing)
                }

                Text("Use this when you want offline processing with the selected Whisper model.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Only Whisper-compatible local models are supported right now. Download one in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }

    // MARK: - Helpers

    private var iconColor: Color { currentRecording.type.brandColor }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var formattedDate: String {
        Self.dateFormatter.string(from: currentRecording.createdAt)
    }

    private var formattedDuration: String {
        let minutes = Int(currentRecording.durationSeconds) / 60
        let seconds = Int(currentRecording.durationSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: currentRecording.fileSizeBytes, countStyle: .file)
    }

    private func deviceSummary(_ sourceDevice: RecordingDeviceInfo) -> String {
        let sampleRate = sourceDevice.sampleRate >= 1000
            ? String(format: "%.1f kHz", sourceDevice.sampleRate / 1000)
            : String(format: "%.0f Hz", sourceDevice.sampleRate)
        return "\(sourceDevice.name) · \(sourceDevice.transportType) · \(sourceDevice.channelCount) ch · \(sampleRate)"
    }
}
