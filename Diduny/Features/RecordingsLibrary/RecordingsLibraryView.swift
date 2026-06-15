import SwiftUI

struct RecordingsLibraryView: View {
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var queueService = RecordingQueueService.shared
    @State private var playbackService = AudioPlaybackService.shared
    @State private var searchText = ""
    @State private var filter: RecordingTypeFilter = .all
    @State private var selectedRecording: Recording? = nil
    @State private var showDeleteConfirmation = false
    @State private var showBulkDeleteConfirmation = false
    @State private var recordingToDelete: Recording? = nil
    @State private var isSelectionMode = false
    @State private var selectedRecordingIds = Set<UUID>()

    enum RecordingTypeFilter: String, CaseIterable {
        case all = "All"
        case meetings = "Meetings"
        case voiceNotes = "Voice notes"
    }

    private var filteredRecordings: [Recording] {
        storage.recordings.filter { recording in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .meetings: matchesFilter = recording.type.isMeetingLike
            case .voiceNotes: matchesFilter = !recording.type.isMeetingLike
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.lowercased()
            return recording.type.displayName.lowercased().contains(query)
                || (recording.transcriptionText?.lowercased().contains(query) ?? false)
        }
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

            if storage.recordings.isEmpty {
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
        .sheet(item: $selectedRecording) { recording in
            RecordingDetailView(recording: recording)
                .frame(minWidth: 640, idealWidth: 700, minHeight: 500)
        }
        .alert("Delete Recording", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let r = recordingToDelete {
                    if playbackService.playingRecordingId == r.id {
                        playbackService.stop()
                    }
                    storage.deleteRecording(r)
                    selectedRecordingIds.remove(r.id)
                    if selectedRecording?.id == r.id { selectedRecording = nil }
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Recordings")
                .font(.title2.bold())
            Spacer()
            Button {
                toggleSelectionMode()
            } label: {
                Label(isSelectionMode ? "Done" : "Select", systemImage: isSelectionMode ? "checkmark.circle" : "checklist")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(storage.recordings.isEmpty)
            .accessibilityIdentifier("Toggle recording selection")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
                TextField("Search transcripts", text: $searchText)
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
            .background(Color(.quaternaryLabelColor).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
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

            if isSelectionMode {
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
                                selectedRecording = recording
                            }
                        },
                        onTranscribe: { transcribe(recording) },
                        onDelete: { requestDelete(recording) },
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

    // MARK: - Context Menu

    @ViewBuilder
    private func recordingContextMenu(for recording: Recording) -> some View {
        Button("Transcribe") {
            transcribe(recording)
        }
        .disabled(recording.status == .processing)

        if recording.type.isMeetingLike {
            Button("Transcribe with Speakers") {
                queueService.enqueue([recording.id], action: .transcribeDiarize, providerOverride: .cloud)
            }
            .disabled(recording.status == .processing)
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
        .disabled(recording.status == .processing)

        if let text = recording.transcriptionText, !text.isEmpty {
            Divider()
            Button("Copy Text") {
                ClipboardService.shared.copy(text: text, behavior: recording.type.clipboardCopyBehavior)
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            requestDelete(recording)
        }
    }

    private func transcribe(_ recording: Recording) {
        queueService.enqueue([recording.id], action: .transcribe)
    }

    private func requestDelete(_ recording: Recording) {
        recordingToDelete = recording
        showDeleteConfirmation = true
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
        if let selectedRecording, ids.contains(selectedRecording.id) {
            self.selectedRecording = nil
        }
        storage.deleteRecordings(ids)
        cancelSelection()
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
