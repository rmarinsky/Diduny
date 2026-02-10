import SwiftUI

struct RecordingsLibraryView: View {
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var queueService = RecordingQueueService.shared
    @State private var selectedIds: Set<UUID> = []
    @State private var filterType: RecordingTypeFilter = .all
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false

    enum RecordingTypeFilter: String, CaseIterable {
        case all = "All"
        case voice = "Voice"
        case translation = "Translation"
        case meeting = "Meeting"
    }

    private var filteredRecordings: [Recording] {
        storage.recordings.filter { recording in
            // Type filter
            let matchesType: Bool
            switch filterType {
            case .all: matchesType = true
            case .voice: matchesType = recording.type == .voice
            case .translation: matchesType = recording.type == .translation
            case .meeting: matchesType = recording.type == .meeting
            }

            // Search filter
            let matchesSearch: Bool
            if searchText.isEmpty {
                matchesSearch = true
            } else {
                let query = searchText.lowercased()
                matchesSearch = recording.type.displayName.lowercased().contains(query)
                    || (recording.transcriptionText?.lowercased().contains(query) ?? false)
            }

            return matchesType && matchesSearch
        }
    }

    private var singleSelectedRecording: Recording? {
        guard selectedIds.count == 1,
              let id = selectedIds.first
        else { return nil }
        return filteredRecordings.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            // Content
            if storage.recordings.isEmpty {
                emptyState
            } else if filteredRecordings.isEmpty {
                noResultsState
            } else {
                HSplitView {
                    recordingsList
                        .frame(minWidth: 300)

                    if let recording = singleSelectedRecording {
                        RecordingDetailView(recording: recording)
                            .frame(minWidth: 250)
                    }
                }
            }

            Divider()

            // Footer
            footer
        }
        .frame(minWidth: 700, minHeight: 400)
        .alert("Delete Recordings", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                storage.deleteRecordings(selectedIds)
                selectedIds.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \(selectedIds.count) recording(s)? This cannot be undone.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $filterType) {
                ForEach(RecordingTypeFilter.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Spacer()

            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - List

    private var recordingsList: some View {
        List(filteredRecordings, selection: $selectedIds) { recording in
            RecordingRowView(recording: recording)
                .tag(recording.id)
                .contextMenu {
                    contextMenu(for: recording)
                }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for recording: Recording) -> some View {
        Button("Transcribe") {
            queueService.enqueue([recording.id], action: .transcribe)
        }
        .disabled(recording.status == .processing)

        Button("Translate") {
            queueService.enqueue([recording.id], action: .translate)
        }
        .disabled(recording.status == .processing)

        if let text = recording.transcriptionText, !text.isEmpty {
            Divider()
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            storage.deleteRecording(recording)
            selectedIds.remove(recording.id)
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
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
                .foregroundColor(.secondary)
            Text("No Results")
                .font(.title3)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            // Stats
            Text("\(filteredRecordings.count) recording(s) · \(formattedTotalSize)")
                .font(.caption)
                .foregroundColor(.secondary)

            // Queue progress
            if queueService.isProcessing {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing (\(queueService.queueCount) remaining)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Batch actions (when items selected)
            if !selectedIds.isEmpty {
                Button("Transcribe") {
                    queueService.enqueue(Array(selectedIds), action: .transcribe)
                }

                Button("Translate") {
                    queueService.enqueue(Array(selectedIds), action: .translate)
                }

                Button("Delete", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: storage.totalSizeBytes, countStyle: .file)
    }
}
