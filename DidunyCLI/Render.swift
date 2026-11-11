import Foundation

/// Markdown for people and agents, JSON with `--json`.
enum Render {
    static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func minutes(_ recording: Recording) -> String {
        "\(max(1, Int((recording.effectiveDurationSeconds / 60).rounded()))) min"
    }

    static func shortID(_ recording: Recording) -> String {
        String(recording.id.uuidString.prefix(8)).lowercased()
    }

    static func people(_ recording: Recording) -> [String] {
        (recording.calendarMeeting?.attendees ?? []).map(\.displayName)
    }

    /// Text other people wrote or said (invitations, transcripts) is marked as data, so an
    /// agent never mistakes it for instructions. `diduny guide` says the same.
    static func untrusted(_ source: String, _ text: String) -> String {
        // A random tag per run: text inside cannot close the block, because it cannot know the tag.
        "<\(untrustedTag) source=\"\(source)\">\n\(text)\n</\(untrustedTag)>"
    }

    static let untrustedTag = "untrusted-" + UUID().uuidString.prefix(8).lowercased()

    // MARK: - List

    static func listMarkdown(_ recordings: [Recording]) -> String {
        guard !recordings.isEmpty else { return "No recordings match.\n" }
        var lines = ["| id | date | length | type | title | people |", "|---|---|---|---|---|---|"]
        for recording in recordings {
            let cells = [shortID(recording), date(recording.createdAt), minutes(recording), recording.type.rawValue,
                         recording.displayTitle, people(recording).joined(separator: ", ")]
            lines.append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "/") }.joined(separator: " | ") + " |")
        }
        // Titles and names can come from an invitation someone else wrote.
        return untrusted("recordings-list", lines.joined(separator: "\n")) + "\n\nShow one: `diduny meetings show <id>`\n"
    }

    static func summary(_ recording: Recording) -> [String: Any] {
        var row: [String: Any] = [
            "id": recording.id.uuidString,
            "shortId": shortID(recording),
            "title": recording.displayTitle,
            "type": recording.type.rawValue,
            "start": ISO8601DateFormatter().string(from: recording.createdAt),
            "durationSeconds": Int(recording.effectiveDurationSeconds),
            "status": recording.status.rawValue,
            "hasTranscript": recording.transcriptionText?.isEmpty == false,
            "people": people(recording)
        ]
        if let meeting = recording.calendarMeeting { row["calendarTitle"] = meeting.title }
        return row
    }

    // MARK: - Show

    static func showMarkdown(_ recording: Recording, audioPath: String, includeTranscript: Bool) -> String {
        // The title can be an invitation's title, so it goes in a data block too.
        var out = ["# Recording \(shortID(recording))", "", untrusted("title", recording.displayTitle), ""]
        out.append("- id: \(recording.id.uuidString)")
        out.append("- type: \(recording.type.rawValue)")
        out.append("- start: \(date(recording.createdAt))")
        out.append("- length: \(minutes(recording))")
        out.append("- status: \(recording.status.rawValue)")
        out.append("- audio: \(audioPath)")
        if let description = recording.description?.nilIfBlank {
            out += ["", "## Description", untrusted("description", description)]
        }
        if let meeting = recording.calendarMeeting {
            // Every field of an invitation is written by whoever sent it.
            var event = ["- title: \(meeting.title)", "- scheduled: \(date(meeting.start)) to \(date(meeting.end))"]
            if let calendar = meeting.calendarTitle { event.append("- calendar: \(calendar)") }
            if let location = meeting.location?.nilIfBlank { event.append("- location: \(location)") }
            if let url = meeting.meetingURL { event.append("- meeting link: \(url.absoluteString)") }
            let attendees = (meeting.attendees ?? []).map { attendee -> String in
                var text = attendee.displayName
                if let email = attendee.email, email != text { text += " <\(email)>" }
                if attendee.isOrganizer { text += " (organizer)" }
                if attendee.isCurrentUser { text += " (you)" }
                return text
            }
            if !attendees.isEmpty { event += ["- attendees:"] + attendees.map { "  - \($0)" } }
            if let notes = meeting.notes?.nilIfBlank { event += ["", "Agenda and notes from the invitation:", notes] }
            out += ["", "## Calendar event", untrusted("calendar-invitation", event.joined(separator: "\n"))]
        }
        if let chapters = recording.chapters, !chapters.isEmpty {
            out += ["", "## Chapters"] + chapters.map { "- [\(time($0.timestampSeconds))] \($0.label)" }
        }
        let versions = recording.resolvedTranscriptHistory
        if versions.count > 1 {
            out += ["", "## Transcript versions"] + versions.enumerated().map {
                "- \($0.offset + 1). \($0.element.kind.rawValue)\($0.element.targetLanguageCode.map { " to \($0)" } ?? ""), \(date($0.element.createdAt))"
            }
        }
        if includeTranscript {
            out += ["", "## Transcript"]
            if let text = recording.displayTranscriptText {
                out.append(recording.transcriptSegments?.isEmpty == false
                    ? "Lines are `[mm:ss] Speaker: text`. Speakers are numbered by the recognizer, not named."
                    : "This transcript has no timestamps.")
                out += ["", untrusted("transcript", text)]
            } else {
                out.append("No transcript yet (status: \(recording.status.rawValue)).")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func showJSON(_ recording: Recording, audioPath: String, includeTranscript: Bool) -> [String: Any] {
        var row = summary(recording)
        row["audioPath"] = audioPath
        if let description = recording.description?.nilIfBlank { row["description"] = description }
        if let meeting = recording.calendarMeeting {
            var event: [String: Any] = [
                "title": meeting.title,
                "start": ISO8601DateFormatter().string(from: meeting.start),
                "end": ISO8601DateFormatter().string(from: meeting.end),
                "attendees": (meeting.attendees ?? []).map { attendee -> [String: Any] in
                    var row: [String: Any] = ["name": attendee.displayName, "organizer": attendee.isOrganizer, "you": attendee.isCurrentUser]
                    if let email = attendee.email { row["email"] = email }
                    return row
                }
            ]
            if let calendar = meeting.calendarTitle { event["calendar"] = calendar }
            if let location = meeting.location { event["location"] = location }
            if let url = meeting.meetingURL { event["meetingURL"] = url.absoluteString }
            if let notes = meeting.notes { event["notes"] = notes }
            row["calendarEvent"] = event
        }
        row["chapters"] = (recording.chapters ?? []).map { ["time": time($0.timestampSeconds), "seconds": Int($0.timestampSeconds), "label": $0.label] }
        if includeTranscript {
            row["transcript"] = recording.transcriptionText ?? ""
            row["segments"] = (recording.transcriptSegments ?? []).map { segment -> [String: Any] in
                var row: [String: Any] = ["time": segment.timestampLabel, "startMs": segment.startMilliseconds, "text": segment.text]
                if let end = segment.endMilliseconds { row["endMs"] = end }
                if let speaker = segment.speakerLabel { row["speaker"] = speaker }
                return row
            }
            row["transcriptVersions"] = recording.resolvedTranscriptHistory.map { version -> [String: Any] in
                var row: [String: Any] = ["kind": version.kind.rawValue, "created": ISO8601DateFormatter().string(from: version.createdAt), "text": version.text]
                if let target = version.targetLanguageCode { row["targetLanguage"] = target }
                return row
            }
        }
        return row
    }

    // MARK: - Search

    struct Hit {
        let recording: Recording
        let time: String?
        let speaker: String?
        let text: String
    }

    static func search(_ query: String, in recordings: [Recording], limit: Int) -> [Hit] {
        let needle = query.lowercased()
        var hits: [Hit] = []
        for recording in recordings {
            if let segments = recording.transcriptSegments, !segments.isEmpty {
                for segment in segments where segment.text.lowercased().contains(needle) {
                    hits.append(Hit(recording: recording, time: segment.timestampLabel, speaker: segment.speakerLabel, text: segment.text))
                    if hits.count >= limit { return hits }
                }
            } else if let text = recording.transcriptionText, let range = text.range(of: query, options: .caseInsensitive) {
                hits.append(Hit(recording: recording, time: nil, speaker: nil, text: snippet(text, around: range)))
                if hits.count >= limit { return hits }
            }
            let meta = [recording.displayTitle, recording.description, recording.calendarMeeting?.notes].compactMap { $0 }
            if meta.contains(where: { $0.lowercased().contains(needle) }) {
                hits.append(Hit(recording: recording, time: nil, speaker: nil, text: "(title, description or invitation)"))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "..." : "") + text[start ..< end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "..." : "")
    }

    static func searchMarkdown(_ hits: [Hit], query: String) -> String {
        guard !hits.isEmpty else { return "Nothing found for \"\(query)\".\n" }
        var lines: [String] = []
        var current: UUID?
        for hit in hits {
            if hit.recording.id != current {
                current = hit.recording.id
                lines += ["", "## \(hit.recording.displayTitle) (\(shortID(hit.recording)), \(date(hit.recording.createdAt)))"]
            }
            let time = hit.time.map { "[\($0)] " } ?? ""
            let speaker = hit.speaker.map { "\($0): " } ?? ""
            lines.append("- \(time)\(speaker)\(hit.text)")
        }
        // Matches are other people's words and invitation text.
        return untrusted("search-results", lines.joined(separator: "\n").trimmingCharacters(in: .newlines)) + "\n"
    }

    static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
