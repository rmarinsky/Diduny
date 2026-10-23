import Foundation
import Observation

struct CalendarAttendee: Codable, Equatable, Hashable, Sendable {
    enum Response: String, Codable, Sendable { case accepted, declined, tentative, pending, unknown }
    var name: String?
    var email: String?
    var response: Response = .unknown
    var isOrganizer = false
    var isCurrentUser = false

    var displayName: String { name?.nilIfBlank ?? email ?? String(localized: "Unknown attendee") }
}

struct CalendarMeeting: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let calendarID: String
    var title: String
    var start: Date
    var end: Date
    var meetingURL: URL?
    var cancelled = false
    var declined = false
    var allDay = false
    // Event details. Optional so meetings stored by older releases still decode.
    var notes: String? = nil
    var location: String? = nil
    var attendees: [CalendarAttendee]? = nil
    var calendarTitle: String? = nil
    var calendarColorRGB: UInt32? = nil
    var eventIdentifier: String? = nil
    var lastModified: Date? = nil
    var myResponse: CalendarAttendee.Response? = nil

    var organizer: CalendarAttendee? { attendees?.first(where: \.isOrganizer) }

    var reminderKey: String { id + "|" + String(start.timeIntervalSince1970) }
    var canRemind: Bool { !cancelled && !declined && !allDay && end > start }
}

struct CalendarReminderLedger: Codable, Equatable {
    private var delivered: [String: Date] = [:]

    mutating func due(_ meetings: [CalendarMeeting], selected: Set<String>, now: Date,
                      fetchedAt: Date?, leadMinutes: Int) -> [CalendarMeeting] {
        delivered = delivered.filter { $0.value > now.addingTimeInterval(-86400) }
        guard let fetchedAt, now.timeIntervalSince(fetchedAt) >= 0,
              now.timeIntervalSince(fetchedAt) <= 300 else { return [] }
        let upcoming = meetings.filter {
            selected.contains($0.calendarID) && $0.canRemind && $0.end > now &&
                $0.start >= now.addingTimeInterval(-300) &&
                $0.start <= now.addingTimeInterval(TimeInterval(max(0, leadMinutes) * 60))
        }.sorted { $0.start < $1.start }
        return upcoming.filter {
            guard delivered[$0.reminderKey] == nil else { return false }
            delivered[$0.reminderKey] = now
            return true
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension CalendarMeeting {
    /// Event description as an agenda: markup removed and the provider's join block cut off.
    static func cleanedNotes(_ notes: String?) -> String? {
        guard var text = notes else { return nil }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        let boilerplate = ["microsoft teams meeting", "join zoom meeting", "join with google meet", "join on your computer",
                           "-::~:~::~", "click here to join the meeting"]
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if boilerplate.contains(where: { lower.hasPrefix($0) }) || trimmed.range(of: #"^[_\-─━=]{10,}$"#, options: .regularExpression) != nil {
                break
            }
            kept.append(trimmed)
        }
        let joined = kept.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return joined.nilIfBlank
    }

    static func joinURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .compactMap { url -> URL? in
                guard isJoinURL(url) else { return nil }
                // Outlook can append <Safe Links URL> to the displayed meeting URL.
                // Trim only this known suffix; never decode queries or unwrap redirect links.
                let value = url.absoluteString
                let suffix = value.range(
                    of: #"(?i)(?:%3c|&lt;|<)https://(?:[a-z0-9-]+\.)*safelinks\.protection\.outlook\.com(?:[/?#]|$)"#,
                    options: .regularExpression)
                guard let suffix else { return url }
                guard let clean = URL(string: String(value[..<suffix.lowerBound])), isJoinURL(clean) else { return nil }
                return clean
            }.first
    }

    static func isJoinURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        let path = url.path
        if host == "meet.google.com" { return path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.range(of: "^/(j|my|wc/join)/[^/]+", options: .regularExpression) != nil
        }
        if host == "webex.com" || host.hasSuffix(".webex.com") {
            return path.hasPrefix("/meet/") || path.contains("/j.php") || path.contains("/join/")
        }
        return host == "meet.jit.si" && path.count > 1

    }
}

struct CalendarAgendaDay: Identifiable, Equatable {
    let day: Date
    let meetings: [CalendarMeeting]
    var id: Date { day }
}

/// Positions are fractions of an eight-hour window starting two hours before the current hour.
struct CalendarTimeline: Equatable {
    enum Phase: Equatable { case past, current, upcoming }
    struct Hour: Equatable { let hour: Int; let position: Double }
    struct Segment: Equatable, Identifiable { let id: String; let from: Double; let to: Double; let phase: Phase }

    let hours: [Hour]
    let now: Double
    let segments: [Segment]

    init(meetings: [CalendarMeeting], now: Date, calendar: Calendar = .current) {
        let start = (calendar.dateInterval(of: .hour, for: now)?.start ?? now).addingTimeInterval(-2 * 3600)
        let span: TimeInterval = 8 * 3600
        let position = { (date: Date) in min(1, max(0, date.timeIntervalSince(start) / span)) }
        hours = (0...8).map { Hour(hour: calendar.component(.hour, from: start.addingTimeInterval(Double($0) * 3600)),
                                   position: Double($0) / 8) }
        self.now = position(now)
        segments = meetings.filter { $0.canRemind && $0.end > start && $0.start < start.addingTimeInterval(span) }
            .sorted { $0.start < $1.start }
            .map { Segment(id: $0.id, from: position($0.start), to: position($0.end), phase: $0.phase(at: now)) }
    }
}

extension CalendarMeeting {
    func phase(at now: Date) -> CalendarTimeline.Phase {
        end <= now ? .past : start <= now ? .current : .upcoming
    }

    /// Today keeps its ended meetings for context; tomorrow lists only meetings that start on it.
    static func agenda(_ meetings: [Self], now: Date, calendar: Calendar = .current) -> [CalendarAgendaDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<2).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let items = meetings.filter { $0.canRemind && $0.start < next && $0.end > day && (offset == 0 || $0.start >= day) }
                .sorted { $0.start < $1.start }
            return items.isEmpty ? nil : CalendarAgendaDay(day: day, meetings: items)
        }
    }
}

enum CalendarJoinDecision: Equatable {
    case joinOnly, recordingUnavailable, openFailed
    case startRecording(showLibrary: Bool), linkExisting(showLibrary: Bool), signInRequired(showAccount: Bool)
    static func resolve(record: Bool, openingSucceeded: Bool, alreadyRecording: Bool, busy: Bool,
                        isSignedIn: Bool = true, hasMeetingURL: Bool = true) -> Self {
        guard openingSucceeded else { return .openFailed }
        guard record else { return .joinOnly }
        guard isSignedIn else { return .signInRequired(showAccount: !hasMeetingURL) }
        if alreadyRecording { return .linkExisting(showLibrary: !hasMeetingURL) }
        return busy ? .recordingUnavailable : .startRecording(showLibrary: !hasMeetingURL)
    }
}

extension CalendarMeeting {
    static func pendingReminders(existing: [Self], incoming: [Self], current: [Self]) -> [Self] {
        let keys = Set((existing + incoming).map(\.reminderKey))
        return current.filter { keys.contains($0.reminderKey) }.sorted { $0.start < $1.start }
    }
}

@MainActor @Observable final class CalendarReminderPresentation {
    var record = false
    func prepare(defaultRecord: Bool, replacingVisible: Bool) {
        if !replacingVisible { record = defaultRecord }
    }
}
