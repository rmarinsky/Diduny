import Foundation

/// Notes written by a model from one recording's transcript. Stored apart from the
/// recording (`notes.json`) so deleting the notes leaves the recording alone.
struct RecordingNote: Identifiable, Codable, Equatable {
    struct Item: Codable, Equatable, Hashable {
        var text: String
        /// `mm:ss` in the transcript where it was said; empty when unknown.
        var time: String
    }

    struct ActionItem: Codable, Equatable, Hashable, Identifiable {
        var id = UUID()
        var owner: String
        var task: String
        var deadline: String
        var time: String
        var done = false
    }

    let id: UUID
    let recordingID: UUID
    var createdAt: Date
    /// Display name of the tool or model that wrote the notes, e.g. "Claude Code, sonnet".
    var writer: String
    var template: NotesTemplate
    var summary: String
    var decisions: [Item]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    /// Points of a voice note; empty for meetings.
    var points: [String] = []
    var topics: [String]? = nil
    /// Items the transcript check did not find in the transcript, kept so the user can see them.
    var removedItems: [String]? = nil
    /// Names the model wrote that are not in the calendar event or the terms.
    var unknownNames: [String]? = nil
    /// Seconds the model took.
    var seconds: Int? = nil
    /// Blocks an agent added at the user's request. Kept apart from what the model wrote, and kept
    /// when the notes are written again.
    struct Addition: Codable, Equatable, Hashable {
        var text: String
        var addedAt: Date
        /// "Claude", "Codex": who added it.
        var author: String
        /// The `diduny` command that added it, so the same command never adds it twice.
        var commandID: UUID? = nil
    }

    var additions: [Addition]? = nil

    /// `processedAt` of the transcript the notes were written from. Nil on notes from older builds.
    var transcriptProcessedAt: Date? = nil

    /// The recording's transcript was redone or edited after these notes were written.
    func isStale(for recording: Recording) -> Bool {
        guard let transcriptProcessedAt, let processedAt = recording.processedAt else { return false }
        return abs(processedAt.timeIntervalSince(transcriptProcessedAt)) >= 1
    }

    /// The transcript a note was written from is no longer the recording's transcript.
    /// Dates are compared to the second: notes.json stores them without fractions.
    static func transcriptChanged(from written: Recording, to current: Recording?) -> Bool {
        guard let current, NotesService.isReady(current) else { return true }
        if current.transcriptionText != written.transcriptionText { return true }
        switch (written.processedAt, current.processedAt) {
        case (nil, nil): return false
        case let (old?, new?): return abs(new.timeIntervalSince(old)) >= 1
        default: return true
        }
    }

    var markdown: String {
        var lines = ["## " + String(localized: "Summary"), summary, ""]
        func section(_ title: String, _ rows: [String]) {
            guard !rows.isEmpty else { return }
            lines.append("## " + title)
            lines += rows.map { "- " + $0 }
            lines.append("")
        }
        section(String(localized: "Topics"), topics ?? [])
        section(String(localized: "Points"), points)
        section(String(localized: "Decisions"), decisions.map { $0.time.isEmpty ? $0.text : "\($0.text) [\($0.time)]" })
        section(String(localized: "Action items"), actionItems.map(\.markdownLine))
        section(String(localized: "Open questions"), openQuestions)
        for addition in additions ?? [] {
            lines.append("## " + String(localized: "Added by \(addition.author), \(addition.addedAt.formatted(date: .abbreviated, time: .shortened))"))
            lines.append(addition.text)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchableText: String {
        ([writer, summary] + points + (topics ?? []) + decisions.map(\.text) + openQuestions
            + actionItems.flatMap { [$0.owner, $0.task] } + (additions ?? []).map(\.text))
            .joined(separator: "\u{0}").lowercased()
    }
}

extension RecordingNote.ActionItem {
    var markdownLine: String {
        var line = "[\(done ? "x" : " ")] \(owner.isEmpty ? String(localized: "No owner") : owner): \(task)"
        if !deadline.isEmpty { line += ", \(deadline)" }
        if !time.isEmpty { line += " [\(time)]" }
        return line
    }
}

enum NotesTemplate: String, Codable, CaseIterable, Identifiable {
    case meeting
    case oneOnOne
    case interview
    case voiceNote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meeting: String(localized: "Meeting")
        case .oneOnOne: String(localized: "One-on-one")
        case .interview: String(localized: "Interview")
        case .voiceNote: String(localized: "Voice note")
        }
    }

    static func forRecording(_ recording: Recording) -> NotesTemplate {
        recording.type.isMeetingLike ? NotesSettings.meetingTemplate : .voiceNote
    }

    var defaultPrompt: String {
        switch self {
        case .meeting:
            """
            You write notes for a meeting from its transcript.
            Write in {language}. Use only what was said in the transcript. If something was not said, do not add it.
            People in the meeting: {people}. Spell their names this way. Terms: {terms}.

            Summary: 2 to 4 sentences on what the meeting was about and how it ended.
            Topics: the subjects discussed, a few words each.
            Decisions: only what the group agreed on. A proposal that nobody answered is not a decision.
            Action items: one each, with the owner only if the transcript says who does the task. Write a deadline only if it was said. A status update on ongoing work is not an action item.
            Open questions: questions that were raised and not answered.

            Leave out greetings, small talk and repeated points.
            """
        case .oneOnOne:
            """
            You write notes for a one-on-one conversation from its transcript.
            Write in {language}. Use only what was said in the transcript. If something was not said, do not add it.
            People in the meeting: {people}. Spell their names this way. Terms: {terms}.

            Summary: 2 to 3 sentences on how the person is doing and what they need.
            Topics: what was talked about, a few words each.
            Decisions: what the two people agreed on.
            Action items: who does what, only when the transcript says who. Write a deadline only if it was said.
            Open questions: what is still open between them.

            Leave out small talk. Do not judge the person.
            """
        case .interview:
            """
            You write notes for an interview from its transcript.
            Write in {language}. Use only what was said in the transcript. If something was not said, do not add it.
            People in the meeting: {people}. Spell their names this way. Terms: {terms}.

            Summary: 2 to 4 sentences on what the candidate said about their experience.
            Topics: the subjects covered, a few words each.
            Decisions: next steps that were agreed, if any.
            Action items: who does what after the interview, only when the transcript says who.
            Open questions: questions that the candidate or the interviewer left open.

            Record what was said. Do not rate or judge the candidate.
            """
        case .voiceNote:
            """
            You write notes from a voice note that one person dictated.
            Write in {language}. Use only what was said. If something was not said, do not add it.
            Terms: {terms}.

            Summary: 1 to 2 sentences.
            Points: the separate ideas, one each.
            Action items: tasks the speaker set for themselves, with an empty owner.

            Leave out repeated points and filler.
            """
        }
    }
}

enum NotesSection: String, CaseIterable, Identifiable {
    case summary, topics, decisions, actionItems, openQuestions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .summary: String(localized: "Summary")
        case .topics: String(localized: "Topics")
        case .decisions: String(localized: "Decisions")
        case .actionItems: String(localized: "Action items")
        case .openQuestions: String(localized: "Open questions")
        }
    }
}

enum NotesLength: String, CaseIterable, Identifiable {
    case short, standard, detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: String(localized: "Short")
        case .standard: String(localized: "Standard")
        case .detailed: String(localized: "Detailed")
        }
    }

    var instruction: String {
        switch self {
        case .short: "Keep the notes short: only the most important items, one short line each."
        case .standard: ""
        case .detailed: "Write detailed notes: include every item that was said, with the context needed to understand it."
        }
    }
}

/// Where the model gets the transcript: lines of about 30 seconds prefixed with `[mm:ss]`,
/// or the plain text when the recording has no timed segments.
enum NotesTranscript {
    static func text(for recording: Recording) -> String {
        guard let segments = recording.transcriptSegments, !segments.isEmpty else {
            return recording.transcriptionText ?? ""
        }
        var lines: [String] = []
        var start: Int?
        var words: [String] = []
        func flush() {
            guard let start, !words.isEmpty else { return }
            let seconds = start / 1000
            lines.append(String(format: "[%02d:%02d] ", seconds / 60, seconds % 60)
                + words.joined(separator: " ").trimmingCharacters(in: .whitespaces))
        }
        for segment in segments {
            if start == nil { start = segment.startMilliseconds }
            let speaker = segment.speakerLabel.map { "\($0): " } ?? ""
            words.append(speaker + segment.text.trimmingCharacters(in: .whitespaces))
            if (segment.endMilliseconds ?? segment.startMilliseconds) - (start ?? 0) >= 30_000 {
                flush()
                start = nil
                words = []
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    static func hasTranscript(_ recording: Recording) -> Bool {
        recording.transcriptionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func hasTimes(_ recording: Recording) -> Bool {
        recording.transcriptSegments?.isEmpty == false
    }

    /// "12:40" or "1:02:05" to seconds.
    static func seconds(from time: String) -> TimeInterval? {
        let parts = time.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ":").compactMap { Int($0) }
        guard (2 ... 3).contains(parts.count) else { return nil }
        return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
    }
}
