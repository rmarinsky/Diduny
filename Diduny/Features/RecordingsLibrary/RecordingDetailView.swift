import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording

    @State private var playbackService = AudioPlaybackService.shared
    @State private var queueService = RecordingQueueService.shared
    @State private var modelManager = WhisperModelManager.shared
    @State private var selectedWhisperModel: String = SettingsStorage.shared.selectedWhisperModel

    private let storage = RecordingsLibraryStorage.shared

    private var downloadedWhisperModels: [WhisperModelManager.WhisperModel] {
        WhisperModelManager.availableModels.filter { modelManager.isModelDownloaded($0) }
    }

    private var hasSonioxKey: Bool {
        KeychainManager.shared.hasAPIKeyFast()
    }

    private var favoriteLanguages: [SupportedLanguage] {
        let codes = SettingsStorage.shared.favoriteLanguages
        return codes.compactMap { SupportedLanguage.language(for: $0) }
    }

    private var otherLanguages: [SupportedLanguage] {
        let favCodes = Set(SettingsStorage.shared.favoriteLanguages)
        return SupportedLanguage.allLanguages.filter { !favCodes.contains($0.code) }
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
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        AudioPlaybackControlView(
            recordingId: recording.id,
            fileURL: storage.audioFileURL(for: recording),
            durationHint: recording.durationSeconds
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
        VStack(alignment: .leading, spacing: 12) {
            // Cloud (Soniox) section
            cloudActionsSection

            Divider()

            // Local (Whisper) section
            localActionsSection

            // Copy text button
            if let text = recording.transcriptionText, !text.isEmpty {
                Divider()
                HStack {
                    Spacer()
                    Button("Copy Text") {
                        ClipboardService.shared.copy(text: text)
                    }
                }
            }
        }
    }

    // MARK: - Cloud Actions

    @ViewBuilder
    private var cloudActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Cloud (Soniox)", systemImage: "cloud.fill")
                .font(.caption)
                .foregroundColor(.blue)

            if hasSonioxKey {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Transcribe + Diarize") {
                        queueService.enqueue(
                            [recording.id],
                            action: .transcribe,
                            providerOverride: .soniox
                        )
                    }
                    .disabled(recording.status == .processing)

                    HStack(spacing: 6) {
                        Text("Translate:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(favoriteLanguages) { lang in
                                    Button(lang.code.uppercased()) {
                                        queueService.enqueue(
                                            [recording.id],
                                            action: .translate,
                                            providerOverride: .soniox,
                                            targetLanguage: lang.code
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(recording.status == .processing)
                                    .help(lang.name)
                                }

                                if !otherLanguages.isEmpty {
                                    Menu("...") {
                                        ForEach(otherLanguages) { lang in
                                            Button(lang.name) {
                                                queueService.enqueue(
                                                    [recording.id],
                                                    action: .translate,
                                                    providerOverride: .soniox,
                                                    targetLanguage: lang.code
                                                )
                                            }
                                        }
                                    }
                                    .menuStyle(.borderlessButton)
                                    .controlSize(.small)
                                    .disabled(recording.status == .processing)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Requires Soniox API key")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }

    // MARK: - Local Actions

    @ViewBuilder
    private var localActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local (Whisper)", systemImage: "desktopcomputer")
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

                    Button("Transcribe") {
                        let modelName = selectedWhisperModel.isEmpty ? downloadedWhisperModels.first?.name : selectedWhisperModel
                        queueService.enqueue(
                            [recording.id],
                            action: .transcribe,
                            providerOverride: .whisperLocal,
                            whisperModelOverride: modelName
                        )
                    }
                    .disabled(recording.status == .processing)
                }
            } else {
                Text("Download a Whisper model in Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }

    // MARK: - Helpers

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

}
