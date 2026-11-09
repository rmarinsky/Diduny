import Foundation

/// The four segments above the day (redesign variant B). Has Translation, YouTube and Batches stay in the
/// filter menu through `RecordingsLibraryView.RecordingTypeFilter`.
enum RecordingsSegment: String, CaseIterable, Identifiable {
    case all
    case meetings
    case notes
    case filesAndLinks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .meetings: String(localized: "Meetings")
        case .notes: String(localized: "Notes")
        case .filesAndLinks: String(localized: "Files and links")
        }
    }

    func matches(_ recording: Recording) -> Bool {
        switch self {
        case .all: true
        case .meetings: recording.type.isMeetingLike
        case .notes: recording.type == .voice || recording.type == .translation
        case .filesAndLinks: recording.type == .fileTranscription
        }
    }
}

/// How finely loose voice notes are grouped. Zoomed out, by clock half-hour; zoomed in, finer, down to single notes.
enum NotesZoom: Int, CaseIterable, Comparable {
    case halfHour
    case quarterHour
    case tenMinutes
    case fiveMinutes
    case single

    /// Bucket length in minutes; nil shows every note on its own.
    var bucketMinutes: Int? {
        switch self {
        case .halfHour: 30
        case .quarterHour: 15
        case .tenMinutes: 10
        case .fiveMinutes: 5
        case .single: nil
        }
    }

    /// Height of one hour on the scale. The prototype's 96 at the widest level.
    var hourHeight: Double {
        switch self {
        case .halfHour: 96
        case .quarterHour: 144
        case .tenMinutes: 216
        case .fiveMinutes: 384
        case .single: 576
        }
    }

    var zoomedIn: NotesZoom? { NotesZoom(rawValue: rawValue + 1) }
    var zoomedOut: NotesZoom? { NotesZoom(rawValue: rawValue - 1) }

    static func < (lhs: NotesZoom, rhs: NotesZoom) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A group the person made from recordings (`TranscriptionBatch.isRecordingGroup`). Grouping only, no audio join.
struct RecordingsDayGroupInput: Equatable {
    let id: UUID
    let name: String
    let recordingIDs: [UUID]
}

struct RecordingsDay: Equatable {
    struct Event: Equatable {
        let meeting: CalendarMeeting
        let attached: [Recording]
        /// Event key plus start: two days of a repeating event never merge.
        var key: String { meeting.reminderKey }
    }

    struct NotesGroup: Equatable {
        /// Day, bucket start minute and bucket length; stable while notes are added.
        let key: String
        let bucketStartMinute: Int
        let bucketMinutes: Int
        let recordings: [Recording]
    }

    struct Group: Equatable {
        let id: UUID
        let name: String
        let recordings: [Recording]
    }

    enum Item: Equatable, Identifiable {
        case event(Event, startMinute: Int, endMinute: Int)
        case recording(Recording, startMinute: Int, endMinute: Int)
        case notes(NotesGroup, startMinute: Int, endMinute: Int)
        case group(Group, startMinute: Int, endMinute: Int)

        var id: String {
            switch self {
            case let .event(event, _, _): "event:" + event.key
            case let .recording(recording, _, _): "recording:" + recording.id.uuidString
            case let .notes(group, _, _): "notes:" + group.key
            case let .group(group, _, _): "group:" + group.id.uuidString
            }
        }

        var startMinute: Int {
            switch self {
            case let .event(_, start, _), let .recording(_, start, _), let .notes(_, start, _), let .group(_, start, _): start
            }
        }

        var endMinute: Int {
            switch self {
            case let .event(_, _, end), let .recording(_, _, end), let .notes(_, _, end), let .group(_, _, end): end
            }
        }

        var isEvent: Bool {
            if case .event = self { return true }
            return false
        }

        /// Every recording the item shows, in time order.
        var recordings: [Recording] {
            switch self {
            case let .event(event, _, _): event.attached
            case let .recording(recording, _, _): [recording]
            case let .notes(group, _, _): group.recordings
            case let .group(group, _, _): group.recordings
            }
        }
    }

    let items: [Item]
    /// Imported files and links of this day, listed under the scale.
    let files: [Recording]

    var isEmpty: Bool { items.isEmpty && files.isEmpty }

    // MARK: - Build

    static func build(
        day: Date,
        recordings: [Recording],
        events: [CalendarMeeting],
        groups: [RecordingsDayGroupInput] = [],
        zoom: NotesZoom,
        calendar: Calendar = .current
    ) -> RecordingsDay {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return RecordingsDay(items: [], files: [])
        }
        let minute = { (date: Date) in Int(date.timeIntervalSince(dayStart) / 60) }
        let dayRecordings = recordings
            .filter { $0.createdAt >= dayStart && $0.createdAt < dayEnd }
            .sorted { $0.createdAt < $1.createdAt }
        let files = dayRecordings.filter { $0.type == .fileTranscription }
        let timed = dayRecordings.filter { $0.type != .fileTranscription }

        // Live events plus the copies stored in linked recordings, so a linked event shows without calendar access.
        var meetings: [String: CalendarMeeting] = [:]
        for meeting in events + timed.compactMap(\.calendarMeeting)
            where !meeting.cancelled && !meeting.allDay && meeting.start < dayEnd && meeting.end > dayStart
            && meetings[meeting.reminderKey] == nil
        {
            meetings[meeting.reminderKey] = meeting
        }

        var attached: [String: [Recording]] = [:]
        var used = Set<UUID>()
        for recording in timed {
            guard let key = eventKey(for: recording, in: Array(meetings.values)) else { continue }
            attached[key, default: []].append(recording)
            used.insert(recording.id)
        }

        var items: [Item] = meetings.values.map { meeting in
            let start = max(0, minute(meeting.start))
            let end = min(24 * 60, max(minute(meeting.end), start + 1))
            return .event(Event(meeting: meeting, attached: attached[meeting.reminderKey] ?? []), startMinute: start, endMinute: end)
        }

        let span = { (recordings: [Recording]) -> (Int, Int) in
            let start = recordings.map { minute($0.createdAt) }.min() ?? 0
            let end = recordings.map { minute($0.createdAt) + max(1, Int(($0.durationSeconds / 60).rounded(.up))) }.max() ?? start + 1
            return (start, min(24 * 60, max(end, start + 1)))
        }

        let timedByID = Dictionary(uniqueKeysWithValues: timed.map { ($0.id, $0) })
        for group in groups {
            let members = group.recordingIDs.compactMap { timedByID[$0] }.filter { !used.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
            guard members.count > 1 else { continue }
            members.forEach { used.insert($0.id) }
            let (start, end) = span(members)
            items.append(.group(Group(id: group.id, name: group.name, recordings: members), startMinute: start, endMinute: end))
        }

        let loose = timed.filter { !used.contains($0.id) }
        let notes = loose.filter(\.isVoiceNote)
        if let bucket = zoom.bucketMinutes {
            let buckets = Dictionary(grouping: notes) { minute($0.createdAt) / bucket }
            for (index, members) in buckets {
                let sorted = members.sorted { $0.createdAt < $1.createdAt }
                let (start, end) = span(sorted)
                if sorted.count == 1 {
                    items.append(.recording(sorted[0], startMinute: start, endMinute: end))
                } else {
                    let bucketStart = index * bucket
                    let key = "\(Int(dayStart.timeIntervalSince1970))-\(bucket)-\(bucketStart)"
                    items.append(.notes(NotesGroup(key: key, bucketStartMinute: bucketStart, bucketMinutes: bucket,
                                                   recordings: sorted), startMinute: start, endMinute: end))
                }
            }
        } else {
            for note in notes {
                let (start, end) = span([note])
                items.append(.recording(note, startMinute: start, endMinute: end))
            }
        }
        for recording in loose where !recording.isVoiceNote {
            let (start, end) = span([recording])
            items.append(.recording(recording, startMinute: start, endMinute: end))
        }

        items.sort { lhs, rhs in
            lhs.startMinute != rhs.startMinute ? lhs.startMinute < rhs.startMinute : lhs.id < rhs.id
        }
        return RecordingsDay(items: items, files: files)
    }

    /// The event a linked recording sits in: the same occurrence (event key plus start), or the same event whose
    /// time contains the recording's START (continuing past the end is fine). Unlinked recordings sit beside events.
    static func eventKey(for recording: Recording, in meetings: [CalendarMeeting]) -> String? {
        guard let linked = recording.calendarMeeting else { return nil }
        if meetings.contains(where: { $0.reminderKey == linked.reminderKey }) { return linked.reminderKey }
        return meetings.first { meeting in
            meeting.id == linked.id && recording.createdAt >= meeting.start && recording.createdAt < meeting.end
        }?.reminderKey
    }

    /// Events of the day whose time contains the recording's start, for the "Attach" button.
    static func overlappingEvents(for recording: Recording, in items: [Item]) -> [CalendarMeeting] {
        guard recording.calendarMeeting == nil, recording.type.canAttachCalendarEvent else { return [] }
        return items.compactMap { item in
            guard case let .event(event, _, _) = item else { return nil }
            let meeting = event.meeting
            return recording.createdAt >= meeting.start && recording.createdAt < meeting.end ? meeting : nil
        }
    }
}

// MARK: - Placement on the hour scale

struct RecordingsDayPlacement: Equatable {
    struct Frame: Equatable {
        let id: String
        var top: Double
        var height: Double
        var column: Int
        var columns: Int
        /// Narrow layout: an unattached recording under an event is indented.
        var indented: Bool
    }

    struct HourLine: Equatable {
        let hour: Int
        let y: Double
    }

    let frames: [Frame]
    let hours: [HourLine]
    let height: Double

    /// Ported from the prototype: overlapping items share a cluster and stand side by side (or stack when narrow);
    /// a block taller than its time pushes the scale below it down, so hour labels stay true.
    static func place(
        _ items: [RecordingsDay.Item],
        hourHeight: Double,
        narrow: Bool,
        minimumHeight: (RecordingsDay.Item) -> Double
    ) -> RecordingsDayPlacement {
        guard let first = items.min(by: { $0.startMinute < $1.startMinute }) else {
            return RecordingsDayPlacement(frames: [], hours: [], height: 0)
        }
        let startHour = first.startMinute / 60
        let y = { (minute: Int) in Double(minute - startHour * 60) / 60 * hourHeight }

        var clusters: [[RecordingsDay.Item]] = []
        var clusterEnd = -1
        for item in items.sorted(by: { $0.startMinute < $1.startMinute }) {
            if !clusters.isEmpty, item.startMinute < clusterEnd {
                clusters[clusters.count - 1].append(item)
                clusterEnd = max(clusterEnd, item.endMinute)
            } else {
                clusters.append([item])
                clusterEnd = item.endMinute
            }
        }

        var frames: [Frame] = []
        var floor = 0.0
        var shift = 0.0
        var shifts: [(minute: Int, shift: Double)] = []
        for cluster in clusters {
            let ordered = cluster.sorted { lhs, rhs in
                lhs.isEvent != rhs.isEvent ? lhs.isEvent : lhs.startMinute < rhs.startMinute
            }
            let clusterEndMinute = cluster.map(\.endMinute).max() ?? 0
            let shifted = { (minute: Int) in y(minute) + shift }
            func height(_ item: RecordingsDay.Item) -> Double {
                max(y(item.endMinute) - y(item.startMinute) - 2, minimumHeight(item))
            }
            var bottom = floor
            if narrow || ordered.count == 1 {
                var previous = floor - 4
                for (index, item) in ordered.enumerated() {
                    let top = max(shifted(item.startMinute), previous + 4)
                    let itemHeight = height(item)
                    let indented = narrow && index > 0 && !item.isEvent && ordered[0].isEvent
                    frames.append(Frame(id: item.id, top: top, height: itemHeight, column: 0, columns: 1, indented: indented))
                    previous = top + itemHeight
                }
                bottom = previous
            } else {
                let clusterTop = max(shifted(cluster[0].startMinute), floor)
                for (index, item) in ordered.enumerated() {
                    let top = max(shifted(item.startMinute), clusterTop)
                    let itemHeight = height(item)
                    frames.append(Frame(id: item.id, top: top, height: itemHeight, column: index,
                                        columns: ordered.count, indented: false))
                    bottom = max(bottom, top + itemHeight)
                }
            }
            floor = bottom + 4
            let natural = shifted(clusterEndMinute)
            if floor > natural { shift += floor - natural }
            shifts.append((clusterEndMinute, shift))
        }

        let endHour = Int((Double(items.map(\.endMinute).max() ?? 0) / 60).rounded(.up))
        let hourY = { (minute: Int) -> Double in
            var applied = 0.0
            for entry in shifts where entry.minute <= minute { applied = entry.shift }
            return y(minute) + applied
        }
        let hours = (startHour ... max(startHour, endHour)).map { HourLine(hour: $0, y: hourY($0 * 60)) }
        let height = max(hourY(endHour * 60), floor) + 8
        return RecordingsDayPlacement(frames: frames, hours: hours, height: height)
    }
}

// MARK: - Week strip, notes filter, suggested name

enum RecordingsWeek {
    /// The seven days of the week that contains `day`.
    static func days(containing day: Date, calendar: Calendar = .current) -> [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: day) else { return [calendar.startOfDay(for: day)] }
        return (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    /// Days that have a recording, so the strip can dim the empty ones.
    static func daysWithRecordings(_ recordings: [Recording], calendar: Calendar = .current) -> Set<Date> {
        Set(recordings.map { calendar.startOfDay(for: $0.createdAt) })
    }
}

enum NotesListFilter: Equatable {
    case all
    case withoutTranscript

    /// The filter appears once a group is long; 40 notes in 30 minutes must stay usable.
    static let threshold = 12

    static func showsFilter(_ notes: [Recording]) -> Bool {
        notes.count > threshold && notes.contains(where: \.needsTranscript)
    }

    func apply(_ notes: [Recording]) -> [Recording] {
        self == .all ? notes : notes.filter(\.needsTranscript)
    }
}

/// Rows of an open notes group on the day; the rest are in the inspector.
enum NotesGroupRows {
    static let shownWhenLong = 8

    static func visible(_ notes: [Recording]) -> (shown: [Recording], hidden: Int) {
        guard notes.count > NotesListFilter.threshold else { return (notes, 0) }
        return (Array(notes.prefix(shownWhenLong)), notes.count - shownWhenLong)
    }
}

struct RecordingNameSuggestion: Equatable {
    enum Source: Equatable { case event, transcript }
    let source: Source
    let name: String

    /// One suggestion: the attached event's title, else the transcript's first words. None when it equals the title.
    static func make(for recording: Recording, maxWords: Int = 7) -> RecordingNameSuggestion? {
        let current = recording.displayTitle
        if let title = recording.calendarMeeting?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty
        {
            return title == current ? nil : RecordingNameSuggestion(source: .event, name: title)
        }
        guard let text = recording.displayTranscriptText else { return nil }
        let firstSentence = text.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? text
        let words = firstSentence.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let name = words.prefix(maxWords).joined(separator: " ")
        let suggestion = (words.count > maxWords ? name + "…" : name).trimmingCharacters(in: .punctuationCharacters)
        guard !suggestion.isEmpty, suggestion != current else { return nil }
        return RecordingNameSuggestion(source: .transcript, name: suggestion)
    }
}

extension Recording {
    var isVoiceNote: Bool { type == .voice || type == .translation }

    var needsTranscript: Bool {
        displayTranscriptText == nil && status != .processing && !status.isInProgressCapture
    }
}

extension Recording.RecordingType {
    /// Meetings and voice notes can be attached to a calendar event; imported files cannot.
    var canAttachCalendarEvent: Bool { self != .fileTranscription }
}
