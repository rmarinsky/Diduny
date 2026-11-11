import Foundation
import os

/// Notes records in `notes.json`, next to the recordings library. At most one note per recording.
@Observable
@MainActor
final class NotesStore {
    static let shared = NotesStore()

    private(set) var notes: [RecordingNote] = []
    private let fileURL: URL

    init(directory: URL? = nil) {
        let appDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diduny")
        fileURL = appDirectory.appendingPathComponent("notes.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = (try? decoder.decode([RecordingNote].self, from: data)) ?? []
        }
    }

    func note(for recordingID: UUID) -> RecordingNote? {
        notes.first { $0.recordingID == recordingID }
    }

    func save(_ note: RecordingNote) {
        notes.removeAll { $0.recordingID == note.recordingID }
        notes.append(note)
        persist()
    }

    func delete(recordingID: UUID) {
        notes.removeAll { $0.recordingID == recordingID }
        persist()
    }

    func setDone(_ done: Bool, item: UUID, in noteID: UUID) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }),
              let itemIndex = notes[noteIndex].actionItems.firstIndex(where: { $0.id == item }) else { return }
        notes[noteIndex].actionItems[itemIndex].done = done
        persist()
    }

    /// Drops notes whose recording was deleted.
    func prune(keeping recordingIDs: Set<UUID>) {
        let before = notes.count
        notes.removeAll { !recordingIDs.contains($0.recordingID) }
        if notes.count != before { persist() }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Writes notes one recording at a time. Never logs transcripts or notes, only sizes and timings.
@Observable
@MainActor
final class NotesService {
    static let shared = NotesService()

    enum JobState: Equatable {
        case waiting
        case writing(part: Int, of: Int)
        case failed(String)
    }

    private(set) var states: [UUID: JobState] = [:]
    private var queue: [UUID] = []
    private var running = false
    private var autoTimer: Timer?
    private let logger = Logger(subsystem: "ua.com.rmarinsky.diduny", category: "Notes")

    private var store: NotesStore { .shared }
    private var library: RecordingsLibraryStorage { .shared }

    func write(_ recordingID: UUID) {
        guard !queue.contains(recordingID), !isWriting(recordingID) else { return }
        queue.append(recordingID)
        states[recordingID] = .waiting
        runNext()
    }

    func isWriting(_ recordingID: UUID) -> Bool {
        if case .writing = states[recordingID] { return true }
        return false
    }

    /// Checks once a minute for new transcripts that should get notes automatically.
    func start() {
        autoTimer?.invalidate()
        autoTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in NotesService.shared.queueAutomaticNotes() }
        }
        queueAutomaticNotes()
    }

    private func queueAutomaticNotes() {
        store.prune(keeping: Set(library.recordings.map(\.id)))
        guard NotesSettings.writer != .off, let since = NotesSettings.autoNotesSince else { return }
        for recording in library.recordings where recording.createdAt >= since
            && NotesTranscript.hasTranscript(recording)
            && (recording.status == .transcribed || recording.status == .translated)
            && store.note(for: recording.id) == nil && states[recording.id] == nil {
            let timing = recording.type.isMeetingLike ? NotesSettings.meetingTiming : NotesSettings.voiceTiming
            if timing == .afterTranscript { write(recording.id) }
        }
    }

    /// A model run slows the Mac, so it never starts while something is being recorded.
    private var isCapturing: Bool {
        library.recordings.contains { $0.status.isInProgressCapture }
    }

    private func runNext() {
        guard !running, let recordingID = queue.first else { return }
        if isCapturing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.runNext() }
            return
        }
        queue.removeFirst()
        running = true
        Task {
            await run(recordingID)
            running = false
            runNext()
        }
    }

    private func run(_ recordingID: UUID) async {
        guard let recording = library.recordings.first(where: { $0.id == recordingID }) else {
            states[recordingID] = nil
            return
        }
        let started = Date()
        do {
            let writer = try await Self.makeWriter()
            let note = try await write(recording, with: writer)
            store.save(note)
            states[recordingID] = nil
            logger.info("Notes written in \(Int(Date().timeIntervalSince(started))) s by \(writer.displayName, privacy: .public)")
        } catch {
            states[recordingID] = .failed(error.localizedDescription)
            logger.error("Notes failed after \(Int(Date().timeIntervalSince(started))) s")
        }
    }

    static func makeWriter(kind: NotesWriterKind = NotesSettings.writer) async throws -> NotesWriter {
        switch kind {
        case .off:
            throw NotesError.noWriter
        case .ollama, .lmStudio:
            return LocalServerWriter(kind: kind, address: NotesSettings.address(for: kind),
                                     model: NotesSettings.model(for: kind))
        case .claudeCode, .codex:
            guard let path = await CLIRunner.locate(kind) else { throw NotesError.notFound(kind.label) }
            guard NotesSettings.approvedPath(for: kind) == path else { throw NotesError.notApproved(kind.label) }
            return CLIWriter(kind: kind, executable: path, model: NotesSettings.model(for: kind))
        }
    }

    func write(_ recording: Recording, with writer: NotesWriter) async throws -> RecordingNote {
        guard NotesTranscript.hasTranscript(recording) else { throw NotesError.noTranscript }
        let template = NotesTemplate.forRecording(recording)
        let instructions = Self.instructions(template: template, recording: recording)
        let transcript = NotesTranscript.text(for: recording)
        let parts = Self.split(transcript, limit: writer.partCharacters)

        var drafts: [NotesDraft] = []
        for (index, part) in parts.enumerated() {
            states[recording.id] = .writing(part: index + 1, of: parts.count)
            let header = parts.count > 1
                ? "\nThis is part \(index + 1) of \(parts.count) of the transcript. Write notes for this part only.\n"
                : ""
            drafts.append(try await writer.write(prompt: instructions + header + "\nTranscript:\n" + part))
        }
        var draft = drafts[0]
        if drafts.count > 1 {
            draft.points = drafts.flatMap { $0.points ?? [] }
            draft.decisions = drafts.flatMap { $0.decisions ?? [] }
            draft.actionItems = drafts.flatMap { $0.actionItems ?? [] }
            draft.openQuestions = drafts.flatMap { $0.openQuestions ?? [] }
            states[recording.id] = .writing(part: parts.count, of: parts.count)
            let summaries = drafts.enumerated().map { "Part \($0.offset + 1): \($0.element.summary)" }.joined(separator: "\n")
            let merged = try? await writer.write(prompt: instructions
                + "\nBelow are summaries of consecutive parts of one recording. Write one summary for the whole recording and leave every other field empty.\n\n"
                + summaries)
            draft.summary = merged?.summary ?? drafts.map(\.summary).joined(separator: " ")
        }
        return RecordingNote(
            id: store.note(for: recording.id)?.id ?? UUID(),
            recordingID: recording.id,
            createdAt: Date(),
            writer: writer.displayName,
            template: template,
            summary: Self.clean(draft.summary),
            decisions: (draft.decisions ?? []).map { .init(text: Self.clean($0.text), time: $0.time ?? "") },
            actionItems: (draft.actionItems ?? []).map {
                .init(owner: Self.clean($0.owner ?? ""), task: Self.clean($0.task),
                      deadline: Self.clean($0.deadline ?? ""), time: $0.time ?? "")
            },
            openQuestions: (draft.openQuestions ?? []).map(Self.clean),
            points: (draft.points ?? []).map(Self.clean)
        )
    }

    static func instructions(template: NotesTemplate, recording: Recording) -> String {
        let attendees = NotesSettings.useCalendarNames ? (recording.calendarMeeting?.attendees ?? []) : []
        let people = attendees.compactMap { $0.name?.nilIfBlank }.joined(separator: ", ")
        let language = NotesSettings.language.nilIfBlank ?? "the language the transcript is mostly spoken in"
        return NotesSettings.prompt(for: template)
            .replacingOccurrences(of: "{language}", with: language)
            .replacingOccurrences(of: "{people}", with: people.nilIfBlank ?? "not known")
            .replacingOccurrences(of: "{terms}", with: NotesSettings.terms.nilIfBlank ?? "none")
            + "\n\nAnswer only with JSON that has the fields summary, points, decisions (text, time),"
            + " actionItems (owner, task, deadline, time) and openQuestions. Times are mm:ss from the transcript, empty when not known.\n"
    }

    /// Cuts at line breaks so a part never splits a timed line.
    static func split(_ text: String, limit: Int?) -> [String] {
        guard let limit, text.count > limit else { return [text] }
        var parts: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + line.count + 1 > limit {
                parts.append(current)
                current = ""
            }
            var line = Substring(line)
            while line.count > limit {
                parts.append(String(line.prefix(limit)))
                line = line.dropFirst(limit)
            }
            current += current.isEmpty ? String(line) : "\n" + line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Model text shown in the UI: straight quotes, no dashes used as punctuation.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: " \u{2014} ", with: ", ")
            .replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
