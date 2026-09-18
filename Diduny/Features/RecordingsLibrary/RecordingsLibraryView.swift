import SwiftUI

enum RecordingsInspectorSelection: Equatable {
    case recording(UUID, parentBatchID: UUID?)
    case batch(UUID)
    case batchComposer

    var parentBatchID: UUID? {
        guard case let .recording(_, parentBatchID) = self else { return nil }
        return parentBatchID
    }

    var backDestination: Self? {
        parentBatchID.map(Self.batch)
    }
}

struct RecordingsLibraryView: View {
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var batchStorage = TranscriptionBatchStorage.shared
    @State private var queueService = RecordingQueueService.shared
    @State private var playbackService = AudioPlaybackService.shared
    @State private var searchText = ""
    @State private var filter: RecordingTypeFilter = .all
    @State private var inspectorSelection: RecordingsInspectorSelection?
    @State private var showDeleteConfirmation = false
    @State private var showBulkDeleteConfirmation = false
    @State private var recordingToDelete: Recording? = nil
    @State private var isSelectionMode = false
    @State private var selectedRecordingIds = Set<UUID>()
    @State private var recordingToRetranscribe: Recording?
    @State private var batchLoadErrorMessage: String?
    @State private var deletionErrorMessage: String?
    @State private var speechErrorMessage: String?

    enum RecordingTypeFilter: String, CaseIterable {
        case all = "All"
        case meetings = "Meetings"
        case voiceNotes = "Voice notes"
        case hasTranslation = "Has Translation"
        case files = "Files"
        case youtube = "YouTube"
        case batches = "Batches"

        var showsBatches: Bool {
            self == .batches
        }

        func matches(_ recording: Recording) -> Bool {
            switch self {
            case .all:
                true
            case .meetings:
                recording.type.isMeetingLike
            case .voiceNotes:
                recording.type == .voice || recording.type == .translation
            case .hasTranslation:
                recording.translationTargetLanguageCode != nil
                    || recording.type == .translation
                    || recording.type == .meetingTranslation
            case .files:
                recording.type == .fileTranscription && !recording.isYouTubeVideo
            case .youtube:
                recording.isYouTubeVideo
            case .batches:
                false
            }
        }
    }

    private var filteredRecordings: [Recording] {
        storage.recordings.filter { recording in
            guard filter.matches(recording) else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.lowercased()
            return recording.displayTitle.lowercased().contains(query)
                || recording.libraryDisplayName.lowercased().contains(query)
                || (recording.description?.lowercased().contains(query) ?? false)
                || (recording.sourceFileName?.lowercased().contains(query) ?? false)
                || (recording.remoteSource?.channelName?.lowercased().contains(query) ?? false)
                || (recording.remoteSource?.description?.lowercased().contains(query) ?? false)
                || recording.resolvedTranscriptHistory.contains { $0.text.lowercased().contains(query) }
        }
    }

    private var filteredBatches: [TranscriptionBatch] {
        batchStorage.batches.filter { $0.matches(searchText, recordings: storage.recordings) }
    }

    private var favoriteLanguages: [SupportedLanguage] {
        let codes = SettingsStorage.shared.favoriteLanguages
        return codes.compactMap { SupportedLanguage.language(for: $0) }
    }

    private var otherLanguages: [SupportedLanguage] {
        let favCodes = Set(SettingsStorage.shared.favoriteLanguages)
        return SupportedLanguage.allLanguages.filter { !favCodes.contains($0.code) }
    }

    private var selectedVisibleCount: Int {
        filteredRecordings.filter { selectedRecordingIds.contains($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            filterChips
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            if filter.showsBatches {
                if batchStorage.batches.isEmpty {
                    batchesEmptyState
                } else if filteredBatches.isEmpty {
                    noResultsState
                } else {
                    batchesCard
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
            } else if storage.recordings.isEmpty {
                emptyState
            } else if filteredRecordings.isEmpty {
                noResultsState
            } else {
                recordingsCard
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .inspector(isPresented: Binding(
            get: { inspectorSelection != nil },
            set: { if !$0 { inspectorSelection = nil } }
        )) {
            inspectorContent
                .frame(minHeight: 500)
        }
        .onAppear {
            batchLoadErrorMessage = batchStorage.loadErrorMessage
            openRequestedRecordingIfAvailable()
            openRequestedBatchComposerIfAvailable()
        }
        .onChange(of: MainWindowController.shared.requestedRecordingID) {
            openRequestedRecordingIfAvailable()
        }
        .onChange(of: storage.recordings) {
            openRequestedRecordingIfAvailable()
        }
        .onChange(of: MainWindowController.shared.requestedBatchComposer) {
            openRequestedBatchComposerIfAvailable()
        }
        .alert("Delete Recording", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let recording = recordingToDelete {
                    if playbackService.playingRecordingId == recording.id {
                        playbackService.stop()
                    }
                    SixtyDBTTSService.shared.stopSpeaking()
                    let id = recording.id
                    if storage.deleteRecording(recording) {
                        selectedRecordingIds.remove(id)
                        if case let .recording(selectedId, _) = inspectorSelection, selectedId == id {
                            inspectorSelection = nil
                        }
                    } else {
                        deletionErrorMessage = "The recording and its files were left unchanged."
                    }
                }
                recordingToDelete = nil
            }
            Button("Cancel", role: .cancel) { recordingToDelete = nil }
        } message: {
            Text("Are you sure you want to delete this recording? This cannot be undone.")
        }
        .alert("Delete Selected Recordings", isPresented: $showBulkDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedRecordings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(selectedRecordingIds.count) selected recordings? This cannot be undone.")
        }
        .alert(
            "Transcribe Again?",
            isPresented: Binding(
                get: { recordingToRetranscribe != nil },
                set: { if !$0 { recordingToRetranscribe = nil } }
            )
        ) {
            Button("Transcribe Again") {
                if let recordingToRetranscribe {
                    queueService.enqueue([recordingToRetranscribe.id], action: .transcribe)
                }
                recordingToRetranscribe = nil
            }
            Button("Cancel", role: .cancel) {
                recordingToRetranscribe = nil
            }
        } message: {
            Text("This adds a new transcript version. Earlier transcripts and source captions stay available.")
        }
        .alert(
            "Batches Couldn't Be Loaded",
            isPresented: Binding(
                get: { batchLoadErrorMessage != nil },
                set: { if !$0 { batchLoadErrorMessage = nil } }
            )
        ) {
            Button("OK") { batchLoadErrorMessage = nil }
        } message: {
            Text(batchLoadErrorMessage ?? "Unknown error")
        }
        .alert(
            "Couldn't Delete Recording",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("OK") { deletionErrorMessage = nil }
        } message: {
            Text(deletionErrorMessage ?? "Unknown error")
        }
        .alert(
            "Speech Failed",
            isPresented: Binding(
                get: { speechErrorMessage != nil },
                set: { if !$0 { speechErrorMessage = nil } }
            )
        ) {
            Button("OK") { speechErrorMessage = nil }
        } message: {
            Text(speechErrorMessage ?? "Unknown error")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Recordings")
                .font(.title2.bold())
            Spacer()
            Button {
                inspectorSelection = .batchComposer
            } label: {
                Label(MainWindowController.batchComposerActionTitle, systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .help("Create a batch from files, URLs, or existing recordings (⇧⌘B)")
            .accessibilityIdentifier("Batch files and URLs")

            if !filter.showsBatches {
                Button {
                    toggleSelectionMode()
                } label: {
                    Label(
                        isSelectionMode ? "Done" : "Select",
                        systemImage: isSelectionMode ? "checkmark.circle" : "checklist"
                    )
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(storage.recordings.isEmpty)
                .accessibilityIdentifier("Toggle recording selection")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
                TextField(filter.showsBatches ? "Search batches" : "Search transcripts", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 160)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Color(.quaternaryLabelColor).opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    private func openRequestedBatchComposerIfAvailable() {
        let controller = MainWindowController.shared
        guard controller.requestedBatchComposer else { return }
        controller.requestedBatchComposer = false
        inspectorSelection = .batchComposer
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(RecordingTypeFilter.allCases, id: \.self) { type in
                    FilterChip(label: type.rawValue, isSelected: filter == type) {
                        filter = type
                    }
                }
                Spacer()
            }

            if isSelectionMode, !filter.showsBatches {
                bulkSelectionBar
            }
        }
    }

    private var bulkSelectionBar: some View {
        HStack(spacing: 8) {
            Label("\(selectedRecordingIds.count) selected", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Button("Select Visible") {
                selectVisibleRecordings()
            }
            .buttonStyle(.link)
            .disabled(filteredRecordings.isEmpty || selectedVisibleCount == filteredRecordings.count)

            Button("Delete") {
                showBulkDeleteConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedRecordingIds.isEmpty)
            .accessibilityIdentifier("Delete selected recordings")

            Button("Cancel") {
                cancelSelection()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Recordings Card

    private var recordingsCard: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filteredRecordings.enumerated()), id: \.element.id) { index, recording in
                    RecordingRowView(
                        recording: recording,
                        onOpen: {
                            if isSelectionMode {
                                toggleSelection(for: recording)
                            } else {
                                inspectorSelection = .recording(recording.id, parentBatchID: nil)
                            }
                        },
                        onTranscribe: { transcribe(recording) },
                        onDelete: { requestDelete(recording) },
                        onProcessRecovery: recording.status == .needsRecovery
                            ? { resolveRecovery(recording, action: .processNow) }
                            : nil,
                        onSaveRecoveryAudio: recording.status == .needsRecovery
                            ? { resolveRecovery(recording, action: .saveAudioOnly) }
                            : nil,
                        isSelectionMode: isSelectionMode,
                        isSelected: selectedRecordingIds.contains(recording.id),
                        onToggleSelection: { toggleSelection(for: recording) }
                    )
                    .contextMenu { recordingContextMenu(for: recording) }
                    if index < filteredRecordings.count - 1 {
                        Divider()
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        )
    }

    private var batchesCard: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filteredBatches.enumerated()), id: \.element.id) { index, batch in
                    Button {
                        inspectorSelection = .batch(batch.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(batch.name).font(.headline).foregroundStyle(.primary)
                                Text(batch.description.isEmpty ? "No description" : batch.description)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("\(batch.recordingIDs.count) recordings")
                                Text(batch.status(in: storage.recordings).rawValue)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < filteredBatches.count - 1 { Divider().padding(.horizontal, 16) }
                }
            }
        }
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorSelection {
        case let .recording(id, parentBatchID):
            if let recording = storage.recordings.first(where: { $0.id == id }) {
                RecordingDetailView(
                    recording: recording,
                    parentBatchName: parentBatchID.flatMap { id in
                        batchStorage.batches.first(where: { $0.id == id })?.name
                    },
                    onBack: parentBatchID == nil ? nil : {
                        inspectorSelection = inspectorSelection?.backDestination
                    },
                    onClose: { inspectorSelection = nil }
                )
                .inspectorColumnWidth(min: 380, ideal: 430, max: 500)
            }
        case let .batch(id):
            if let batch = batchStorage.batches.first(where: { $0.id == id }) {
                TranscriptionBatchInspectorView(
                    batch: batch,
                    onOpenRecording: { recordingID in
                        inspectorSelection = .recording(recordingID, parentBatchID: id)
                    },
                    onClose: { inspectorSelection = nil }
                )
                .inspectorColumnWidth(min: 380, ideal: 430, max: 500)
            }
        case .batchComposer:
            NewTranscriptionBatchPanel(
                recordings: storage.recordings,
                onCreated: { batchID in
                    inspectorSelection = .batch(batchID)
                },
                onClose: { inspectorSelection = nil }
            )
            .inspectorColumnWidth(min: 430, ideal: 480, max: 560)
        case nil:
            EmptyView()
        }
    }

    private func openRequestedRecordingIfAvailable() {
        let controller = MainWindowController.shared
        guard let id = controller.requestedRecordingID,
              let recording = storage.recordings.first(where: { $0.id == id })
        else { return }

        inspectorSelection = .recording(recording.id, parentBatchID: nil)
        controller.requestedRecordingID = nil
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func recordingContextMenu(for recording: Recording) -> some View {
        if recording.status == .needsRecovery {
            Button("Process Now") {
                resolveRecovery(recording, action: .processNow)
            }
            Button("Save Audio Only") {
                resolveRecovery(recording, action: .saveAudioOnly)
            }
            Button("Discard Recovery", role: .destructive) {
                resolveRecovery(recording, action: .discard)
            }
            Divider()
        }

        Button(recording.remoteSource == nil ? "Transcribe" : "Transcribe Again…") {
            transcribe(recording)
        }
        .disabled(recording.status == .processing || recording.status.isInProgressCapture)

        if recording.type.isMeetingLike {
            Button("Transcribe with Speakers") {
                queueService.enqueue([recording.id], action: .transcribeDiarize, providerOverride: .cloud)
            }
            .disabled(recording.status == .processing || recording.status.isInProgressCapture)
        }

        Menu("Translate to") {
            ForEach(favoriteLanguages) { lang in
                Button(lang.name) {
                    queueService.enqueue([recording.id], action: .translate, targetLanguage: lang.code)
                }
            }
            if !otherLanguages.isEmpty {
                Divider()
                ForEach(otherLanguages) { lang in
                    Button(lang.name) {
                        queueService.enqueue([recording.id], action: .translate, targetLanguage: lang.code)
                    }
                }
            }
        }
        .disabled(recording.status == .processing || recording.status.isInProgressCapture)

        if let text = recording.displayTranscriptText {
            Divider()
            Button("Copy Text") {
                ClipboardService.shared.copy(text: text, behavior: recording.type.clipboardCopyBehavior)
            }
            if let primary = recording.resolvedTranscriptHistory.first {
                Button("Speak Text") {
                    speakVersion(primary)
                }
                .disabled(recording.status == .processing || recording.status.isInProgressCapture)
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            requestDelete(recording)
        }
    }

    private func speakVersion(_ version: TranscriptVersion) {
        Task {
            do {
                try await SixtyDBTTSService.shared.toggleSpeak(
                    versionId: version.id,
                    text: version.text,
                    languageCode: version.targetLanguageCode ?? version.sourceLanguageCode
                )
            } catch {
                speechErrorMessage = error.localizedDescription
            }
        }
    }

    private func transcribe(_ recording: Recording) {
        if recording.remoteSource != nil,
           !(recording.transcriptionText?.isEmpty ?? true)
        {
            recordingToRetranscribe = recording
        } else {
            queueService.enqueue([recording.id], action: .transcribe)
        }
    }

    private func requestDelete(_ recording: Recording) {
        recordingToDelete = recording
        showDeleteConfirmation = true
    }

    private func resolveRecovery(
        _ recording: Recording,
        action: MeetingRecoveryService.RecoveryAction
    ) {
        Task { @MainActor in
            let ok = await MeetingRecoveryService.shared.resolve(
                recordingID: recording.id,
                action: action
            )
            if !ok, action != .discard {
                DictationOverlayController.shared.showInfo(
                    message: "Could not recover meeting audio",
                    duration: 3
                )
            }
        }
    }

    private func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode {
            selectedRecordingIds.removeAll()
        }
    }

    private func cancelSelection() {
        isSelectionMode = false
        selectedRecordingIds.removeAll()
    }

    private func toggleSelection(for recording: Recording) {
        if selectedRecordingIds.contains(recording.id) {
            selectedRecordingIds.remove(recording.id)
        } else {
            selectedRecordingIds.insert(recording.id)
        }
    }

    private func selectVisibleRecordings() {
        selectedRecordingIds.formUnion(filteredRecordings.map(\.id))
    }

    private func deleteSelectedRecordings() {
        let ids = selectedRecordingIds
        guard !ids.isEmpty else { return }
        if let playingId = playbackService.playingRecordingId, ids.contains(playingId) {
            playbackService.stop()
        }
        SixtyDBTTSService.shared.stopSpeaking()
        if case let .recording(id, _) = inspectorSelection, ids.contains(id) {
            inspectorSelection = nil
        }
        if storage.deleteRecordings(ids) {
            cancelSelection()
        } else {
            deletionErrorMessage = "The selected recordings and their files were left unchanged."
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundColor(Color("BrandTintSoft"))
            Text("No Recordings Yet")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Your voice, translation, and meeting recordings will appear here.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(Color("BrandTintSoft"))
            Text("No Results")
                .font(.title3)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var batchesEmptyState: some View {
        ContentUnavailableView(
            "No Batches Yet",
            systemImage: "square.stack.3d.up",
            description: Text("Create a batch to group related recordings and transcripts.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    isSelected
                        ? Color.accentColor
                        : Color(.quaternaryLabelColor).opacity(0.08),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? Color.clear : Color(.separatorColor),
                            lineWidth: 0.5
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
