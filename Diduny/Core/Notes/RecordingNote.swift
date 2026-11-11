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

    var markdown: String {
        var lines = ["## " + String(localized: "Summary"), summary, ""]
        func section(_ title: String, _ rows: [String]) {
            guard !rows.isEmpty else { return }
            lines.append("## " + title)
            lines += rows.map { "- " + $0 }
            lines.append("")
        }
        section(String(localized: "Points"), points)
        section(String(localized: "Decisions"), decisions.map { $0.time.isEmpty ? $0.text : "\($0.text) [\($0.time)]" })
        section(String(localized: "Action items"), actionItems.map(\.markdownLine))
        section(String(localized: "Open questions"), openQuestions)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchableText: String {
        ([writer, summary] + points + decisions.map(\.text) + openQuestions
            + actionItems.flatMap { [$0.owner, $0.task] })
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
    case voiceNote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meeting: String(localized: "Meeting")
        case .voiceNote: String(localized: "Voice note")
        }
    }

    static func forRecording(_ recording: Recording) -> NotesTemplate {
        recording.type.isMeetingLike ? .meeting : .voiceNote
    }

    var defaultPrompt: String {
        switch self {
        case .meeting:
            """
            You write notes for a meeting from its transcript.
            Write in {language}. Use only what was said in the transcript. If something was not said, do not add it.
            People in the meeting: {people}. Spell their names this way. Terms: {terms}.

            Summary: 2 to 4 sentences on what the meeting was about and how it ended.
            Decisions: only what the group agreed on. A proposal that nobody answered is not a decision.
            Action items: one each, with the owner only if the transcript says who does the task, otherwise leave the owner empty. Write a deadline only if it was said.
            Open questions: questions that were raised and not answered.

            For each decision and action item give the time in the transcript where it was said.
            Leave out greetings, small talk and repeated points. If a section has nothing, leave it empty.
            """
        case .voiceNote:
            """
            You write notes from a voice note that one person dictated.
            Write in {language}. Use only what was said. If something was not said, do not add it.
            Terms: {terms}.

            Summary: 1 to 2 sentences.
            Points: the separate ideas, one each.
            Action items: tasks the speaker set for themselves, with an empty owner.

            Leave out repeated points and filler. If a section has nothing, leave it empty.
            """
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
}
