import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Notes block in a recording: none, waiting, writing, checking, done, error.
/// Hidden when nobody writes notes and the recording has none.
struct RecordingNotesSection: View {
    let recording: Recording
    @State private var store = NotesStore.shared
    @State private var service = NotesService.shared

    var body: some View {
        if NotesSettings.group != .off || store.note(for: recording.id) != nil {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    Text("Notes").font(DS.Font.headline)
                    Spacer()
                    if let note = store.note(for: recording.id), service.states[recording.id] == nil {
                        NoteActions(note: note, title: recording.displayTitle)
                    }
                }
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.states[recording.id] {
        case let .waiting(reason):
            Text(reason ?? String(localized: "Waiting to write notes.")).font(DS.Font.callout).foregroundStyle(.secondary)
        case let .writing(part, total):
            progress(total > 1 ? String(localized: "Writing notes, part \(part) of \(total).") : String(localized: "Writing notes."))
        case .checking:
            progress(String(localized: "Checking the notes against the transcript."))
        case let .failed(message):
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(message).font(DS.Font.callout).foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { service.write(recording.id) }
            }
        case nil:
            if let note = store.note(for: recording.id) {
                NoteBody(note: note, recording: recording)
            } else if NotesTranscript.hasTranscript(recording) {
                HStack(spacing: DS.Space.sm) {
                    if NotesSettings.writer == .off {
                        Text("Choose who writes the notes in Notes settings.")
                            .font(DS.Font.callout).foregroundStyle(.secondary)
                        Button("Open Notes settings") { MainWindowController.shared.showWindow(section: .notesSettings) }
                    } else {
                        Button("Write notes") { service.write(recording.id) }
                        TemplateMenu(title: "Template", recordingID: recording.id)
                        Text("\(NotesTemplate.forRecording(recording).label) template, written by \(NotesSettings.writer.label).")
                            .font(DS.Font.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Notes can be written once the recording has a transcript.")
                    .font(DS.Font.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: DS.Space.sm) {
            ProgressView().controlSize(.small)
            Text(text).font(DS.Font.callout).foregroundStyle(.secondary)
        }
    }
}

/// Writes the notes for one recording with a template other than the default.
private struct TemplateMenu: View {
    let title: LocalizedStringKey
    let recordingID: UUID

    var body: some View {
        Menu(title) {
            ForEach(NotesTemplate.allCases) { template in
                Button(template.label) { NotesService.shared.write(recordingID, template: template) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Copy, write again, save as Markdown, delete the notes.
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
                Button("Write again") { NotesService.shared.write(note.recordingID, template: note.template) }
                Menu("Write again as") {
                    ForEach(NotesTemplate.allCases) { template in
                        Button(template.label) { NotesService.shared.write(note.recordingID, template: template) }
                    }
                }
                Button("Save as Markdown...") { saveMarkdown() }
                Divider()
                Button("Delete the notes", role: .destructive) { try? NotesStore.shared.delete(recordingID: note.recordingID) }
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
    let recording: Recording
    @State private var showRemoved = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if !note.summary.isEmpty {
                Text(note.summary).font(DS.Font.body).textSelection(.enabled)
            }
            list("Topics", (note.topics ?? []).map { ($0, "") })
            list("Points", note.points.map { ($0, "") })
            list("Decisions", note.decisions.map { ($0.text, $0.time) })
            if !note.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Action items").font(DS.Font.headline)
                    ForEach(note.actionItems) { item in
                        ActionItemRow(item: item, noteID: note.id, recording: recording,
                                      unknownOwner: note.unknownNames?.contains(item.owner) == true)
                    }
                }
            }
            list("Open questions", note.openQuestions.map { ($0, "") })
            if let removed = note.removedItems, !removed.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Button(showRemoved ? "Hide removed items" : "The check removed \(removed.count) items. Show them") {
                        showRemoved.toggle()
                    }
                    .buttonStyle(.link)
                    if showRemoved {
                        ForEach(removed, id: \.self) { Text($0).font(DS.Font.callout).foregroundStyle(.secondary).strikethrough() }
                    }
                }
            }
            if let error = NotesStore.shared.lastError {
                Text(error).font(DS.Font.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text(footer).font(DS.Font.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        var text = String(localized: "\(note.template.label) template, \(note.writer), \(note.createdAt.formatted(date: .abbreviated, time: .shortened)).")
        if let names = note.unknownNames, !names.isEmpty {
            text += " " + String(localized: "Check these names, they are not in the calendar event: \(names.joined(separator: ", ")).")
        }
        return text + " " + String(localized: "A model can get names and facts wrong.")
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
                        TimeLink(time: row.1, recording: recording)
                    }
                }
            }
        }
    }
}

/// A transcript time; clicking it plays the recording from there.
struct TimeLink: View {
    let time: String
    let recording: Recording

    var body: some View {
        if !time.isEmpty {
            Button(time) { play() }
                .buttonStyle(.link)
                .font(DS.Font.callout)
                .monospacedDigit()
                .help("Play from \(time)")
                .disabled(!RecordingsLibraryStorage.shared.hasPlayableAudio(for: recording))
        }
    }

    private func play() {
        guard let seconds = NotesTranscript.seconds(from: time) else { return }
        let player = AudioPlaybackService.shared
        if player.playingRecordingId != recording.id || !player.isPlaying {
            player.togglePlayback(recordingId: recording.id,
                                  fileURL: RecordingsLibraryStorage.shared.audioFileURL(for: recording),
                                  trimRange: recording.trimRange)
        }
        player.seek(to: seconds - (recording.trimRange?.startSeconds ?? 0))
    }
}

struct ActionItemRow: View {
    let item: RecordingNote.ActionItem
    let noteID: UUID
    let recording: Recording?
    var unknownOwner = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Toggle(isOn: Binding(get: { item.done },
                                 set: { NotesStore.shared.setDone($0, item: item.id, in: noteID) })) {
                (Text(owner).underline(unknownOwner, pattern: .dot) + Text(": " + rest))
                    .font(DS.Font.body)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
            }
            .toggleStyle(.checkbox)
            .help(unknownOwner ? String(localized: "This name is not in the calendar event or the terms.") : "")
            Spacer(minLength: DS.Space.sm)
            if let recording { TimeLink(time: item.time, recording: recording) }
        }
    }

    private var owner: String { item.owner.isEmpty ? String(localized: "No owner") : item.owner }
    private var rest: String { item.deadline.isEmpty ? item.task : "\(item.task), \(item.deadline)" }
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
                if store.notes.isEmpty {
                    NotesEmptyState()
                } else {
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
                    if tab == .notes { notesList } else { actionItemsList }
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
                            Text(row.recording.displayTitle).font(DS.Font.groupHeading)
                            Spacer()
                            Button("Open recording") { MainWindowController.shared.showRecording(id: row.recording.id) }
                            NoteActions(note: row.note, title: row.recording.displayTitle)
                        }
                        NoteBody(note: row.note, recording: row.recording)
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
                ActionItemRow(item: entry.item, noteID: entry.row.note.id, recording: entry.row.recording)
                Text(entry.row.recording.displayTitle).font(DS.Font.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// No notes yet: says what is missing and offers the one next step.
private struct NotesEmptyState: View {
    @State private var service = NotesService.shared
    @State private var library = RecordingsLibraryStorage.shared

    var body: some View {
        let waiting = service.recordingsWithoutNotes(meetingsOnly: false, since: nil)
        let meetings = waiting.filter(\.type.isMeetingLike).count
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("No notes yet").font(DS.Font.groupHeading)
            if NotesSettings.writer == .off {
                Text("Notes are a short record of a meeting: summary, decisions and who does what. Choose who writes them: a model on this Mac or an AI subscription you already have.")
                    .font(DS.Font.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose who writes notes") { MainWindowController.shared.showWindow(section: .notesSettings) }
                    .buttonStyle(.borderedProminent).tint(DS.Palette.accent)
                    .padding(.top, DS.Space.xs)
            } else if !waiting.isEmpty {
                Text("\(meetings) meetings and \(waiting.count - meetings) voice notes have a transcript and no notes. \(NotesSettings.writer.label) can write them.")
                    .font(DS.Font.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.sm) {
                    Button("Write notes for earlier recordings") { MainWindowController.shared.showWindow(section: .notesSettings) }
                        .buttonStyle(.borderedProminent).tint(DS.Palette.accent)
                    Button("Open a recording") { MainWindowController.shared.showWindow(section: .recordings) }
                }
                .padding(.top, DS.Space.xs)
            } else {
                Text("Notes appear here after a meeting is transcribed. \(NotesSettings.writer.label) writes them.")
                    .font(DS.Font.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.top, DS.Space.xl)
    }
}
