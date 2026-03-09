import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording

    @State private var playbackService = AudioPlaybackService.shared
    @State private var queueService = RecordingQueueService.shared
    @State private var modelManager = WhisperModelManager.shared
    @State private var selectedWhisperModel: String = SettingsStorage.shared.selectedWhisperModel
#if DEBUG
    @State private var debugEntries: [RecordingDebugEntry] = []
    @State private var selectedDebugCategory: DebugCategoryFilter = .all
#endif

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

#if DEBUG
            debugLogsSection
                .padding(12)

            Divider()
#endif

            // Actions
            actionsSection
                .padding(12)
        }
#if DEBUG
        .task(id: recording.id) {
            await refreshDebugEntries()
        }
#endif
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

#if DEBUG
    private enum DebugCategoryFilter: String, CaseIterable {
        case all = "All"
        case app = "App"
        case decision = "Decision"
        case http = "HTTP"

        var category: RecordingDebugCategory? {
            switch self {
            case .all: nil
            case .app: .app
            case .decision: .decision
            case .http: .http
            }
        }
    }

    private var filteredDebugEntries: [RecordingDebugEntry] {
        let base = debugEntries.sorted { $0.timestamp > $1.timestamp }
        guard let category = selectedDebugCategory.category else { return base }
        return base.filter { $0.category == category }
    }

    private var debugLogsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Dev Logs")
                    .font(.headline)

                Spacer()

                Picker("Category", selection: $selectedDebugCategory) {
                    ForEach(DebugCategoryFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Button("Refresh") {
                    Task {
                        await refreshDebugEntries()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if filteredDebugEntries.isEmpty {
                Text("No debug logs for this recording yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredDebugEntries) { entry in
                            Text("\(formattedDebugTime(entry.timestamp)) [\(entry.category.title)] \(entry.source.map { "\($0): " } ?? "")\(entry.message)")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 180)
            }
        }
    }
#endif

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
                        ClipboardService.shared.copy(text: text, behavior: recording.type.clipboardCopyBehavior)
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
        case .fileTranscription: .purple
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var formattedDate: String {
        Self.dateFormatter.string(from: recording.createdAt)
    }

    private var formattedDuration: String {
        let minutes = Int(recording.durationSeconds) / 60
        let seconds = Int(recording.durationSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: recording.fileSizeBytes, countStyle: .file)
    }

#if DEBUG
    private func refreshDebugEntries() async {
        debugEntries = await RecordingDebugStore.shared.entries(for: recording.id)
    }

    private func formattedDebugTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
#endif

}
