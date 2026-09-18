import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordingDetailView: View {
    let recording: Recording
    let parentBatchName: String?
    let onBack: (() -> Void)?
    let onClose: () -> Void

    @State private var playbackService = AudioPlaybackService.shared
    @State private var queueService = RecordingQueueService.shared
    @State private var modelManager = WhisperModelManager.shared
    @State private var selectedWhisperModel: String = SettingsStorage.shared.selectedWhisperModel
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var showRetranscriptionConfirmation = false
    @State private var requestedRetranscriptionProvider: TranscriptionProvider = .cloud
    @State private var requestedWhisperModel: String?
    @State private var title: String
    @State private var description: String
    @State private var showDeleteConfirmation = false
    @State private var operationErrorMessage: String?

    init(
        recording: Recording,
        parentBatchName: String? = nil,
        onBack: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.recording = recording
        self.parentBatchName = parentBatchName
        self.onBack = onBack
        self.onClose = onClose
        _title = State(initialValue: recording.title ?? recording.displayTitle)
        _description = State(initialValue: recording.description ?? recording.remoteSource?.description ?? "")
    }

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

    private var translationPair: TranslationLanguagePair {
        SettingsStorage.shared.resolveTranslationLanguagePair()
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

    private var hasPlayableAudio: Bool {
        storage.hasPlayableAudio(for: currentRecording)
    }

    private var isInProgressCapture: Bool {
        currentRecording.status.isInProgressCapture
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    detailsSection
                        .padding(16)

                    if currentRecording.remoteSource != nil {
                        Divider()
                        youtubeSourceSection
                            .padding(16)
                    }

                    Divider()
                    playbackAndProcessingSection
                        .padding(16)

                    Divider()
                    transcriptionSection
                        .padding(16)

                    Divider()
                    deleteSection
                        .padding(16)
                }
            }
        }
        .onExitCommand {
            onClose()
        }
        .alert("Transcribe Again?", isPresented: $showRetranscriptionConfirmation) {
            Button("Transcribe Again") {
                enqueueRequestedRetranscription()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This adds a new transcript version. Earlier transcripts, source captions, and YouTube identity stay available."
            )
        }
        .alert("Delete Recording and Files?", isPresented: $showDeleteConfirmation) {
            Button("Delete Recording", role: .destructive) {
                if playbackService.playingRecordingId == currentRecording.id {
                    playbackService.stop()
                }
                SixtyDBTTSService.shared.stopSpeaking()
                if storage.deleteRecording(currentRecording) {
                    onClose()
                } else {
                    operationErrorMessage = "The recording and its files were left unchanged."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes the recording, stored media, transcript history, translations, and every batch reference."
            )
        }
        .alert(
            "Recording Change Failed",
            isPresented: Binding(
                get: { operationErrorMessage != nil },
                set: { if !$0 { operationErrorMessage = nil } }
            )
        ) {
            Button("OK") { operationErrorMessage = nil }
        } message: {
            Text(operationErrorMessage ?? "Unknown error")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Label("Back to Batch", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Back to \(parentBatchName ?? "Batch")")
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: currentRecording.libraryIconName)
                    .font(.title2)
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(currentRecording.displayTitle)
                        .font(.headline)
                        .lineLimit(2)

                    Text("\(currentRecording.libraryDisplayName) · \(formattedDuration) · \(formattedDate)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    if let sourceDevice = currentRecording.sourceDevice {
                        Text(deviceSummary(sourceDevice))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityIdentifier("Close recording detail")
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DETAILS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Recording title", text: $title)
            TextField("Description", text: $description, axis: .vertical)
                .lineLimit(2 ... 4)
            HStack {
                Spacer()
                Button("Save Details") {
                    if !storage.updateDetails(
                        id: currentRecording.id,
                        title: title,
                        description: description
                    ) {
                        operationErrorMessage = "The title and description were left unchanged."
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var youtubeSourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUTUBE SOURCE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let remoteSource = currentRecording.remoteSource {
                VStack(alignment: .leading, spacing: 5) {
                    Text(remoteSource.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Link(remoteSource.canonicalURL.absoluteString, destination: remoteSource.canonicalURL)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let channel = remoteSource.channelName {
                        Text(channel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Playback and processing

    private var playbackSection: some View {
        AudioPlaybackControlView(
            recordingId: currentRecording.id,
            fileURL: storage.audioFileURL(for: currentRecording),
            durationHint: currentRecording.durationSeconds
        )
        .disabled(!hasPlayableAudio)
    }

    private var playbackAndProcessingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PLAYBACK")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            playbackSection
                .padding(12)
                .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            if isInProgressCapture {
                Text(
                    currentRecording.status == .recording
                        ? "Recording in progress — playback and transcription become available once it's finalized."
                        : "This session needs recovery before it can be played or transcribed. Resolve it from the recordings list."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    localTranscriptionButton
                    if !currentRecording.requiresLocalTranscription {
                        cloudTranscriptionButton
                    }
                }

                if currentRecording.requiresLocalTranscription {
                    Text("Imported files and YouTube audio are transcribed locally to protect cloud limits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                translationMenu
            }
        }
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TRANSCRIPT HISTORY")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(currentRecording.resolvedTranscriptHistory.count) versions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Color(.quaternaryLabelColor).opacity(0.12),
                        in: Capsule()
                    )
            }

            if currentRecording.status == .processing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(queueStatusText ?? "Processing...").foregroundStyle(.secondary)
                }
            } else if currentRecording.status == .failed {
                Label(
                    currentRecording.errorMessage ?? "Transcription failed",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }

            let versions = currentRecording.resolvedTranscriptHistory.sorted {
                $0.createdAt > $1.createdAt
            }
            if versions.isEmpty {
                Text("No transcription yet")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(versions) { version in
                    transcriptCard(version)
                }
            }

            if let artifacts = currentRecording.sourceCaptionArtifacts,
               !artifacts.isEmpty
            {
                Divider()
                ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(
                                artifact.provenance == .youtubeAuthored
                                    ? "YouTube Captions · Authored"
                                    : "YouTube Captions · Automatic",
                                systemImage: "captions.bubble"
                            )
                            .font(.headline)
                            Spacer()
                            Button("Export…") {
                                exportCaption(artifact)
                            }
                            .controlSize(.small)
                            Button("Copy Captions") {
                                ClipboardService.shared.copy(
                                    text: artifact.text,
                                    behavior: .raw
                                )
                            }
                            .controlSize(.small)
                        }
                        ScrollView {
                            Text(artifact.text)
                                .textSelection(.enabled)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 190)
                    }
                    .padding(12)
                    .background(
                        Color(.textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }
        }
    }

    private func transcriptCard(_ version: TranscriptVersion) -> some View {
        let text = version.displayText
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transcriptVersionTitle(version)).font(.headline)
                    Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 0) {
                    TranscriptSpeakButton(
                        versionId: version.id,
                        text: version.text,
                        languageCode: version.targetLanguageCode ?? version.sourceLanguageCode
                    )
                    .padding(.trailing, 8)
                    Button {
                        ClipboardService.shared.copy(text: text, behavior: .raw)
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    Menu {
                        Button("Save as TXT File…") {
                            exportText(
                                text,
                                title: "Save Transcript",
                                defaultFileName: "\(currentRecording.type.displayName) Transcript.txt"
                            )
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Transcript export options")
                    .accessibilityLabel("Transcript export options")
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)
        }
        .padding(12)
        .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func transcriptVersionTitle(_ version: TranscriptVersion) -> String {
        switch version.kind {
        case .cloud:
            return "Cloud Transcript"
        case .local:
            return version.modelIdentifier.map { "Local Transcript · \($0)" } ?? "Local Transcript"
        case .translation:
            if let source = version.sourceLanguageCode, let target = version.targetLanguageCode {
                return "Translation · \(source.uppercased()) → \(target.uppercased())"
            }
            return "Translation"
        }
    }

    // MARK: - Processing actions

    private func exportCaption(_ artifact: TranscriptArtifact) {
        exportText(
            artifact.text,
            title: "Export Source Captions",
            defaultFileName: "YouTube Captions - \(artifact.languageCode).txt"
        )
    }

    private func exportText(_ text: String, title: String, defaultFileName: String) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            operationErrorMessage = "Could not save the text file: \(error.localizedDescription)"
        }
    }

    private var cloudTranscriptionButton: some View {
        Group {
            if supportsSpeakerLabels {
                Menu {
                    Button("Standard Transcription") {
                        requestRetranscription(provider: .cloud)
                    }
                    Button("Transcribe with Speakers") {
                        queueService.enqueue(
                            [currentRecording.id],
                            action: .transcribeDiarize,
                            providerOverride: .cloud
                        )
                    }
                } label: {
                    Label("Transcribe in Cloud", systemImage: "cloud")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    requestRetranscription(provider: .cloud)
                } label: {
                    Label("Transcribe in Cloud", systemImage: "cloud")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .buttonStyle(.bordered)
        .disabled(currentRecording.status == .processing)
        .frame(maxWidth: .infinity)
    }

    private var localTranscriptionButton: some View {
        Button {
            let modelName = selectedWhisperModel.isEmpty
                ? downloadedWhisperModels.first?.name
                : selectedWhisperModel
            requestRetranscription(provider: .local, whisperModel: modelName)
        } label: {
            Label("Transcribe Locally", systemImage: "waveform")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(currentRecording.status == .processing || downloadedWhisperModels.isEmpty)
        .frame(maxWidth: .infinity)
        .help(
            downloadedWhisperModels.isEmpty
                ? "Download a Whisper model in Settings first."
                : "Uses \(selectedLocalModelName)."
        )
    }

    private var translationMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(favoriteLanguages) { lang in
                    Button(lang.name) { translate(to: lang.code) }
                }
                if !favoriteLanguages.isEmpty, !otherLanguages.isEmpty { Divider() }
                ForEach(otherLanguages) { lang in
                    Button(lang.name) { translate(to: lang.code) }
                }
            } label: {
                HStack {
                    Text(
                        "Translate: \(translationPair.languageA.uppercased()) → \(currentRecording.translationTargetLanguageCode?.uppercased() ?? "Choose Language")"
                    )
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .disabled(currentRecording.status == .processing)

            Text(
                "Translation direction: \(translationPair.languageA.uppercased()) → \(currentRecording.translationTargetLanguageCode?.uppercased() ?? "choose a language")"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DELETE RECORDING")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(
                "This permanently deletes the recording, all source media and generated files, every transcript and translation version, and removes it from attached batches."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Delete Recording…", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
    }

    private var selectedLocalModelName: String {
        downloadedWhisperModels
            .first(where: { $0.name == selectedWhisperModel })?
            .displayName
            ?? downloadedWhisperModels.first?.displayName
            ?? "the selected local model"
    }

    // MARK: - Helpers

    private func translate(to languageCode: String) {
        queueService.enqueue(
            [currentRecording.id],
            action: .translate,
            providerOverride: .cloud,
            targetLanguage: languageCode
        )
    }

    private func requestRetranscription(
        provider: TranscriptionProvider,
        whisperModel: String? = nil
    ) {
        requestedRetranscriptionProvider = provider
        requestedWhisperModel = whisperModel
        if currentRecording.remoteSource != nil,
           !(currentRecording.transcriptionText?.isEmpty ?? true)
        {
            showRetranscriptionConfirmation = true
        } else {
            enqueueRequestedRetranscription()
        }
    }

    private func enqueueRequestedRetranscription() {
        queueService.enqueue(
            [currentRecording.id],
            action: .transcribe,
            providerOverride: requestedRetranscriptionProvider,
            whisperModelOverride: requestedWhisperModel
        )
        requestedWhisperModel = nil
    }

    private var iconColor: Color {
        currentRecording.libraryBrandColor
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var formattedDate: String {
        let start = Self.dateFormatter.string(from: currentRecording.createdAt)
        if currentRecording.status == .recording {
            return "\(start) – …"
        }
        if let ended = currentRecording.resolvedEndedAt {
            let endFormatter = DateFormatter()
            endFormatter.dateStyle = .none
            endFormatter.timeStyle = .short
            return "\(start) – \(endFormatter.string(from: ended))"
        }
        return start
    }

    private var formattedDuration: String {
        let totalSeconds: Int
        if currentRecording.durationSeconds > 0 {
            totalSeconds = Int(currentRecording.durationSeconds)
        } else if let ended = currentRecording.resolvedEndedAt {
            totalSeconds = max(0, Int(ended.timeIntervalSince(currentRecording.createdAt)))
        } else {
            totalSeconds = 0
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func deviceSummary(_ sourceDevice: RecordingDeviceInfo) -> String {
        let sampleRate = sourceDevice.sampleRate >= 1000
            ? String(format: "%.1f kHz", sourceDevice.sampleRate / 1000)
            : String(format: "%.0f Hz", sourceDevice.sampleRate)
        return "\(sourceDevice.name) · \(sourceDevice.transportType) · \(sourceDevice.channelCount) ch · \(sampleRate)"
    }
}
