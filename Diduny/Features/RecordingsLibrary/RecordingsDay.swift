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
    /// A recording's exact place on the scale, in wall-clock minutes from midnight (fractional).
    struct Span: Equatable {
        let recording: Recording
        let start: Double
        let end: Double
    }

    struct Event: Equatable {
        let meeting: CalendarMeeting
        let attached: [Recording]
        /// The attached recordings at their real times, placed inside the event's column.
        var spans: [Span] = []
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
        var spans: [Span] = []
    }

    enum Item: Equatable, Identifiable {
        case event(Event, startMinute: Double, endMinute: Double)
        case recording(Recording, startMinute: Double, endMinute: Double)
        case notes(NotesGroup, startMinute: Double, endMinute: Double)
        case group(Group, startMinute: Double, endMinute: Double)

        var id: String {
            switch self {
            case let .event(event, _, _): "event:" + event.key
            case let .recording(recording, _, _): "recording:" + recording.id.uuidString
            case let .notes(group, _, _): "notes:" + group.key
            case let .group(group, _, _): "group:" + group.id.uuidString
            }
        }

        var startMinute: Double {
            switch self {
            case let .event(_, start, _), let .recording(_, start, _), let .notes(_, start, _), let .group(_, start, _): start
            }
        }

        var endMinute: Double {
            switch self {
            case let .event(_, _, end), let .recording(_, _, end), let .notes(_, _, end), let .group(_, _, end): end
            }
        }

        var isEvent: Bool {
            if case .event = self { return true }
            return false
        }

        /// Recordings placed inside the block at their real times (events and groups).
        var childSpans: [Span]? {
            switch self {
            case let .event(event, _, _): event.spans
            case let .group(group, _, _): group.spans
            case .recording, .notes: nil
            }
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
        // Wall-clock minutes, so hour labels stay right on a 23- or 25-hour DST day; outside the day, real time.
        let minute = { (date: Date) -> Double in
            if date < dayStart { return date.timeIntervalSince(dayStart) / 60 }
            if date >= dayEnd { return 24 * 60 + date.timeIntervalSince(dayEnd) / 60 }
            let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
                + (Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1e9) / 60
        }
        let spanOf = { (recording: Recording) -> Span in
            let start = minute(recording.createdAt)
            return Span(recording: recording, start: start, end: min(24 * 60, start + max(0, recording.durationSeconds) / 60))
        }
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
            let end = min(24 * 60, max(minute(meeting.end), start))
            let members = attached[meeting.reminderKey] ?? []
            return .event(Event(meeting: meeting, attached: members, spans: members.map(spanOf)),
                          startMinute: start, endMinute: end)
        }

        let span = { (recordings: [Recording]) -> (Double, Double) in
            let spans = recordings.map(spanOf)
            let start = spans.map(\.start).min() ?? 0
            return (start, max(spans.map(\.end).max() ?? start, start))
        }

        let timedByID = Dictionary(uniqueKeysWithValues: timed.map { ($0.id, $0) })
        for group in groups {
            let members = group.recordingIDs.compactMap { timedByID[$0] }.filter { !used.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
            guard members.count > 1 else { continue }
            members.forEach { used.insert($0.id) }
            let (start, end) = span(members)
            items.append(.group(Group(id: group.id, name: group.name, recordings: members, spans: members.map(spanOf)),
                                startMinute: start, endMinute: end))
        }

        let loose = timed.filter { !used.contains($0.id) }
        let notes = loose.filter(\.isVoiceNote)
        if let bucket = zoom.bucketMinutes {
            let buckets = Dictionary(grouping: notes) { Int(minute($0.createdAt).rounded(.down)) / bucket }
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

/// Time-accurate placement: a block starts at its start time and is as tall as it lasts. A block shorter than
/// `minimumHeight` is drawn at that height for its label, with `trueHeight` showing the real span. Blocks whose
/// drawn rectangles overlap stand side by side in lanes, as in a calendar.
struct RecordingsDayPlacement: Equatable {
    struct Frame: Equatable {
        let id: String
        var top: Double
        var height: Double
        /// The real span on the scale; smaller than `height` when the minimum height applies.
        var trueHeight: Double
        var column: Int
        var columns: Int
    }

    struct HourLine: Equatable {
        let hour: Int
        let y: Double
    }

    static let minimumHeight: Double = 30

    let startHour: Int
    let hourHeight: Double
    let frames: [Frame]
    let hours: [HourLine]
    let height: Double

    static func y(_ minute: Double, startHour: Int, hourHeight: Double) -> Double {
        (minute - Double(startHour * 60)) / 60 * hourHeight
    }

    /// Height from duration, and the drawn height with the minimum applied.
    static func heights(start: Double, end: Double, hourHeight: Double, minimum: Double = minimumHeight)
        -> (drawn: Double, true: Double)
    {
        let real = max(0, end - start) / 60 * hourHeight
        return (max(real, minimum), real)
    }

    /// Lanes for spans in one column: greedy first free lane; a cluster of touching spans shares a lane count.
    static func lanes(_ spans: [(id: String, top: Double, bottom: Double)]) -> [String: (lane: Int, lanes: Int)] {
        var result: [String: (lane: Int, lanes: Int)] = [:]
        var cluster: [(id: String, lane: Int)] = []
        var laneBottoms: [Double] = []
        var clusterBottom = -Double.infinity
        func close() {
            for entry in cluster { result[entry.id] = (entry.lane, laneBottoms.count) }
            cluster = []
            laneBottoms = []
        }
        for span in spans.sorted(by: { $0.top != $1.top ? $0.top < $1.top : $0.id < $1.id }) {
            if span.top >= clusterBottom { close() }
            let lane = laneBottoms.firstIndex { $0 <= span.top } ?? laneBottoms.count
            if lane == laneBottoms.count { laneBottoms.append(span.bottom) } else { laneBottoms[lane] = span.bottom }
            cluster.append((span.id, lane))
            clusterBottom = max(clusterBottom, span.bottom)
        }
        close()
        return result
    }

    static func place(_ items: [RecordingsDay.Item], hourHeight: Double,
                      minimumHeight: Double = minimumHeight) -> RecordingsDayPlacement
    {
        guard let first = items.map(\.startMinute).min() else {
            return RecordingsDayPlacement(startHour: 0, hourHeight: hourHeight, frames: [], hours: [], height: 0)
        }
        let startHour = Int((first / 60).rounded(.down))
        var drawn: [String: (top: Double, height: Double, true: Double)] = [:]
        for item in items {
            let top = y(item.startMinute, startHour: startHour, hourHeight: hourHeight)
            var size = heights(start: item.startMinute, end: item.endMinute, hourHeight: hourHeight, minimum: minimumHeight)
            if let spans = item.childSpans {
                // An attached recording that runs past the event's end stays inside the event's column.
                let inner = children(spans, containerStart: item.startMinute, hourHeight: hourHeight, minimumHeight: minimumHeight)
                let bottom = inner.map { $0.top + $0.height }.max() ?? 0
                size.drawn = max(size.drawn, bottom)
            }
            drawn[item.id] = (top, size.drawn, size.true)
        }
        let lanes = lanes(drawn.map { (id: $0.key, top: $0.value.top, bottom: $0.value.top + $0.value.height) })
        let frames = items.map { item -> Frame in
            let box = drawn[item.id]!
            let lane = lanes[item.id] ?? (0, 1)
            return Frame(id: item.id, top: box.top, height: box.height, trueHeight: box.true,
                         column: lane.lane, columns: lane.lanes)
        }
        let lastMinute = items.map(\.endMinute).max() ?? first
        let endHour = max(startHour + 1, Int((lastMinute / 60).rounded(.up)))
        let hours = (startHour ... endHour).map { HourLine(hour: $0, y: y(Double($0 * 60), startHour: startHour, hourHeight: hourHeight)) }
        let height = max(hours.last?.y ?? 0, frames.map { $0.top + $0.height }.max() ?? 0) + 8
        return RecordingsDayPlacement(startHour: startHour, hourHeight: hourHeight, frames: frames, hours: hours, height: height)
    }

    /// Recordings inside an event or group, relative to its top, at their real times, in lanes.
    static func children(_ spans: [RecordingsDay.Span], containerStart: Double, hourHeight: Double,
                         minimumHeight: Double = minimumHeight) -> [Frame]
    {
        let boxes = spans.map { span -> (id: String, top: Double, height: Double, true: Double) in
            let size = heights(start: span.start, end: span.end, hourHeight: hourHeight, minimum: minimumHeight)
            return (span.recording.id.uuidString, (span.start - containerStart) / 60 * hourHeight, size.drawn, size.true)
        }
        let lanes = lanes(boxes.map { ($0.id, $0.top, $0.top + $0.height) })
        return boxes.map { box in
            let lane = lanes[box.id] ?? (0, 1)
            return Frame(id: box.id, top: box.top, height: box.height, trueHeight: box.true, column: lane.lane, columns: lane.lanes)
        }
    }
}

/// What the day shows while a recording is worked on. Read from the stored status, which the queue sets at
/// enqueue and clears at the end, so the observed library is enough (no polling).
enum RecordingsProcessingState: Equatable {
    case none
    case working
    case failed

    static func of(_ recording: Recording) -> Self {
        switch recording.status {
        case .processing: .working
        case .failed: .failed
        default: .none
        }
    }

    /// An event or a notes group: working while any member works, else failed if any failed.
    static func of(_ recordings: [Recording]) -> Self {
        let states = recordings.map(of)
        if states.contains(.working) { return .working }
        return states.contains(.failed) ? .failed : .none
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

enum NotesListFilter: Hashable {
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

/// Holds the built day so redraws and inspector reads never rebuild it; only a change of input does.
struct RecordingsDayCache {
    struct Inputs: Equatable {
        let day: Date
        let recordings: [Recording]
        let events: [CalendarMeeting]
        let groups: [RecordingsDayGroupInput]
        let zoom: NotesZoom
    }

    private(set) var inputs: Inputs?
    private(set) var day = RecordingsDay(items: [], files: [])
    /// How many times the day was built (tests).
    private(set) var builds = 0

    mutating func update(_ next: Inputs, calendar: Calendar = .current) {
        let normalized = Inputs(day: calendar.startOfDay(for: next.day), recordings: next.recordings,
                                events: next.events, groups: next.groups, zoom: next.zoom)
        guard normalized != inputs else { return }
        inputs = normalized
        day = RecordingsDay.build(day: normalized.day, recordings: normalized.recordings, events: normalized.events,
                                  groups: normalized.groups, zoom: normalized.zoom, calendar: calendar)
        builds += 1
    }
}
