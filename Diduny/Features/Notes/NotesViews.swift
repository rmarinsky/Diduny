import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Notes block in a recording: none, waiting, writing, done, error.
struct RecordingNotesSection: View {
    let recording: Recording
    @State private var store = NotesStore.shared
    @State private var service = NotesService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Notes").font(DS.Font.headline)
                Spacer()
                actions
            }
            content
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let note = store.note(for: recording.id), service.states[recording.id] == nil {
            NoteActions(note: note, title: recording.displayTitle)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.states[recording.id] {
        case .waiting:
            Text("Waiting to write notes.").font(DS.Font.callout).foregroundStyle(.secondary)
        case let .writing(part, total):
            HStack(spacing: DS.Space.sm) {
                ProgressView().controlSize(.small)
                Text(total > 1 ? "Writing notes, part \(part) of \(total)." : "Writing notes.")
                    .font(DS.Font.callout).foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(message).font(DS.Font.callout).foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { service.write(recording.id) }
            }
        case nil:
            if let note = store.note(for: recording.id) {
                NoteBody(note: note)
            } else if NotesTranscript.hasTranscript(recording) {
                HStack(spacing: DS.Space.sm) {
                    Button("Write notes") { service.write(recording.id) }
                        .disabled(NotesSettings.writer == .off)
                    Text(NotesSettings.writer == .off
                        ? "Choose who writes the notes in Notes settings."
                        : "Written by \(NotesSettings.writer.label).")
                        .font(DS.Font.callout).foregroundStyle(.secondary)
                    if NotesSettings.writer == .off {
                        Button("Open Notes settings") { MainWindowController.shared.showWindow(section: .notesSettings) }
                    }
                }
            } else {
                Text("Notes can be written once the recording has a transcript.")
                    .font(DS.Font.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Copy, save as Markdown, write again, delete the notes.
struct NoteActions: View {
    let note: RecordingNote
    let title: String

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.markdown, forType: .string)
            }
            Menu("More") {
                Button("Write again") { NotesService.shared.write(note.recordingID) }
                Button("Save as Markdown...") { saveMarkdown() }
                Divider()
                Button("Delete notes", role: .destructive) { NotesStore.shared.delete(recordingID: note.recordingID) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ("# \(title)\n\n" + note.markdown).write(to: url, atomically: true, encoding: .utf8)
    }
}

struct NoteBody: View {
    let note: RecordingNote

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(note.summary).font(DS.Font.body).textSelection(.enabled)
            list("Points", note.points.map { ($0, "") })
            list("Decisions", note.decisions.map { ($0.text, $0.time) })
            if !note.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Action items").font(DS.Font.headline)
                    ForEach(note.actionItems) { item in
                        ActionItemRow(item: item, noteID: note.id)
                    }
                }
            }
            list("Open questions", note.openQuestions.map { ($0, "") })
            Text("Written by \(note.writer) on \(note.createdAt.formatted(date: .abbreviated, time: .shortened)). A model can get names and facts wrong.")
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func list(_ title: LocalizedStringKey, _ rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title).font(DS.Font.headline)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        Text("•").foregroundStyle(.secondary)
                        Text(row.0).font(DS.Font.body).textSelection(.enabled)
                        Spacer(minLength: DS.Space.sm)
                        if !row.1.isEmpty {
                            Text(row.1).font(DS.Font.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

struct ActionItemRow: View {
    let item: RecordingNote.ActionItem
    let noteID: UUID

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Toggle(isOn: Binding(get: { item.done },
                                 set: { NotesStore.shared.setDone($0, item: item.id, in: noteID) })) {
                Text(label).font(DS.Font.body).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: DS.Space.sm)
            if !item.time.isEmpty {
                Text(item.time).font(DS.Font.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var label: String {
        let owner = item.owner.isEmpty ? String(localized: "No owner") : item.owner
        return item.deadline.isEmpty ? "\(owner): \(item.task)" : "\(owner): \(item.task), \(item.deadline)"
    }
}

/// The Notes section: every note, searchable, with an Action items tab across notes.
struct NotesView: View {
    enum Tab: String, CaseIterable { case notes, actionItems }

    @State private var store = NotesStore.shared
    @State private var library = RecordingsLibraryStorage.shared
    @State private var search = ""
    @State private var tab: Tab = .notes
    @State private var selection: UUID?

    private var rows: [(note: RecordingNote, recording: Recording)] {
        let recordings = Dictionary(uniqueKeysWithValues: library.recordings.map { ($0.id, $0) })
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.notes
            .compactMap { note in recordings[note.recordingID].map { (note, $0) } }
            .filter { query.isEmpty || $0.note.searchableText.contains(query) || $0.recording.displayTitle.lowercased().contains(query) }
            .sorted { $0.recording.createdAt > $1.recording.createdAt }
    }

    var body: some View {
        PageScaffold(title: "Notes", scrolls: false) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack {
                    Picker("Show", selection: $tab) {
                        Text("Notes").tag(Tab.notes)
                        Text("Action items").tag(Tab.actionItems)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    Spacer()
                    TextField("Search", text: $search, prompt: Text("Search notes"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                if store.notes.isEmpty {
                    EmptyState(icon: "doc.text", title: "No notes yet",
                               message: "Open a recording and press Write notes, or turn on automatic notes in Notes settings.")
                } else if tab == .notes {
                    notesList
                } else {
                    actionItemsList
                }
            }
        }
    }

    private var notesList: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            List(rows, id: \.note.id, selection: $selection) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.recording.displayTitle).font(DS.Font.headline).lineLimit(1)
                    Text(row.recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DS.Font.caption).foregroundStyle(.secondary)
                    Text(row.note.summary).font(DS.Font.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.vertical, DS.Space.xs)
            }
            .frame(width: 280)
            ScrollView {
                if let row = rows.first(where: { $0.note.id == selection }) ?? rows.first {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.recording.displayTitle).font(DS.Font.pageTitle)
                            Spacer()
                            Button("Open recording") { MainWindowController.shared.showRecording(id: row.recording.id) }
                            NoteActions(note: row.note, title: row.recording.displayTitle)
                        }
                        NoteBody(note: row.note)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var actionItemsList: some View {
        let items = rows.flatMap { row in row.note.actionItems.map { (item: $0, row: row) } }
            .sorted { !$0.item.done && $1.item.done }
        return List(items, id: \.item.id) { entry in
            VStack(alignment: .leading, spacing: 2) {
                ActionItemRow(item: entry.item, noteID: entry.row.note.id)
                Text(entry.row.recording.displayTitle).font(DS.Font.caption).foregroundStyle(.secondary)
            }
        }
    }
}
