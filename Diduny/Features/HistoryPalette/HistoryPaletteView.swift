import SwiftUI

struct HistoryPaletteView: View {
    @State private var searchText = ""
    @State private var storage = RecordingsLibraryStorage.shared

    private var filteredRecordings: [Recording] {
        let withText = storage.recordings.filter { $0.transcriptionText != nil && !$0.transcriptionText!.isEmpty }
        if searchText.isEmpty {
            return Array(withText.prefix(20))
        }
        let query = searchText.lowercased()
        return withText.filter {
            $0.transcriptionText!.lowercased().contains(query)
                || $0.type.displayName.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit {
                        if let first = filteredRecordings.first {
                            copyAndClose(first)
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Results
            if filteredRecordings.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No transcriptions yet" : "No results")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRecordings) { recording in
                            HistoryPaletteRow(recording: recording) {
                                copyAndClose(recording)
                            }
                            if recording.id != filteredRecordings.last?.id {
                                Divider()
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(filteredRecordings.count) item(s)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("View All") {
                    HistoryPaletteWindowController.shared.closeWindow()
                    RecordingsLibraryWindowController.shared.showWindow()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 420, height: 360)
    }

    private func copyAndClose(_ recording: Recording) {
        guard let text = recording.transcriptionText else { return }
        ClipboardService.shared.copy(text: text)
        HistoryPaletteWindowController.shared.closeWindow()
    }
}

// MARK: - Row

private struct HistoryPaletteRow: View {
    let recording: Recording
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: recording.type.iconName)
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preview)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Text(recording.type.displayName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formattedDate)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var preview: String {
        guard let text = recording.transcriptionText else { return "" }
        if text.count <= 120 { return text }
        return String(text.prefix(120)) + "..."
    }

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: recording.createdAt, relativeTo: Date())
    }
}
