import Foundation

public struct PageNode: Sendable {
    public let role: String
    public let label: String
    public let url: URL?
    public init(role: String, label: String, url: URL? = nil) { self.role = role; self.label = label; self.url = url }
}

public struct VisibleEvent: Equatable, Sendable {
    public let title: String
    public let displayedTime: String
    public let displayedDate: String
    public let cancelled: Bool
}

public struct CalendarSnapshot: Sendable {
    public let provider: CalendarProvider
    public let readAt: Date
    public let events: [VisibleEvent]
    public let meetingLinks: [URL]
}

public enum CalendarReadError: Error, LocalizedError {
    case consentRequired, wrongPage
    public var errorDescription: String? {
        switch self {
        case .consentRequired: return String(localized: "Approve this read before accessing the calendar.")
        case .wrongPage: return String(localized: "Select a Google Calendar or Outlook Calendar tab in the chosen browser, then retry.")
        }
    }
}

public enum CalendarExtraction {
    public static func read(approved: Bool, pageURL: URL, nodes: () throws -> [PageNode]) throws -> CalendarSnapshot {
        guard approved else { throw CalendarReadError.consentRequired }
        guard let provider = CalendarPage.provider(for: pageURL) else { throw CalendarReadError.wrongPage }
        let content = try nodes()
        var linkIDs = Set<String>()
        let events = content.compactMap { node -> VisibleEvent? in
            guard node.role == "AXButton", let event = event(from: node.label, provider: provider) else { return nil }
            return event
        }
        let links = content.compactMap { node -> URL? in
            guard node.role == "AXLink", let url = node.url, isMeetingURL(url),
                  linkIDs.insert(url.absoluteString).inserted else { return nil }
            return url
        }
        return CalendarSnapshot(provider: provider, readAt: Date(), events: events, meetingLinks: links)
    }

    public static func isMeetingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        switch url.host?.lowercased() {
        case "meet.google.com": return groups(#"^/([a-z]{3}-[a-z]{4}-[a-z]{3})/?$"#, url.path) != nil
        case "teams.microsoft.com", "teams.live.com":
            return url.path.hasPrefix("/l/meetup-join/") || groups(#"^/meet/([0-9]+)/?$"#, url.path) != nil
        default: return false
        }
    }

    private static func event(from label: String, provider: CalendarProvider) -> VisibleEvent? {
        let title: String, time: String, date: String
        switch provider {
        case .google:
            guard let match = groups(#"^(\d{1,2}:\d{2}(?:\s?[AP]M)?\s*[–−-]\s*\d{1,2}:\d{2}(?:\s?[AP]M)?),\s*(.+),\s*(\d{1,2}\s+[^,]+\s+\d{4})$"#, label) else { return nil }
            time = match[0]; date = match[2]
            let metadata = [", Персональне", ", Календар:", ", Personal", ", Calendar:"]
            guard let boundary = metadata.compactMap({ match[1].range(of: $0)?.lowerBound }).min() else { return nil }
            title = String(match[1][..<boundary])
        case .microsoft:
            guard let match = groups(#"^(.+?),\s*(\d{1,2}:\d{2}(?:\s?[AP]M)?\s+to\s+\d{1,2}:\d{2}(?:\s?[AP]M)?),\s*((?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),\s+\w+\s+\d{1,2},\s+\d{4})(?:,|$)"#, label) else { return nil }
            title = match[0]; time = match[1]; date = match[2]
        }
        guard !title.isEmpty else { return nil }
        return VisibleEvent(title: title, displayedTime: time, displayedDate: date,
                            cancelled: ["Canceled:", "Cancelled:", "Скасовано:"].contains(where: title.hasPrefix))
    }

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

/// Turns a browser calendar read into meetings the menu and the Recordings day can show.
enum BrowserCalendarMeetings {
    static func make(events: [VisibleEvent], windowName: String, sourceTitle: String, from: Date, to: Date,
                     calendar: Calendar = .current) -> [CalendarMeeting] {
        let calendarID = "browser:" + windowName
        return events.compactMap { event in
            guard let range = range(dateText: event.displayedDate, timeText: event.displayedTime, calendar: calendar),
                  range.start < to, range.end > from else { return nil }
            return CalendarMeeting(
                id: calendarID + ":" + String(range.start.timeIntervalSince1970) + ":" + event.title,
                calendarID: calendarID, title: event.title, start: range.start, end: range.end,
                cancelled: event.cancelled, calendarTitle: sourceTitle)
        }
    }

    static func range(dateText: String, timeText: String, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        guard let day = day(dateText, calendar: calendar), let clock = clock(timeText) else { return nil }
        guard let start = calendar.date(bySettingHour: clock.startHour, minute: clock.startMinute, second: 0, of: day),
              var end = calendar.date(bySettingHour: clock.endHour, minute: clock.endMinute, second: 0, of: day) else { return nil }
        if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
        return (start, end)
    }

    private static func day(_ text: String, calendar: Calendar) -> Date? {
        let formats = ["EEEE, MMMM d, yyyy", "MMMM d, yyyy", "d MMMM yyyy"]
        let locales = [Locale(identifier: "en_US_POSIX"), Locale(identifier: "uk_UA"), calendar.locale ?? .current]
        for format in formats {
            for locale in locales {
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.locale = locale
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return calendar.startOfDay(for: date) }
            }
        }
        return nil
    }

    private static func clock(_ text: String) -> (startHour: Int, startMinute: Int, endHour: Int, endMinute: Int)? {
        let pattern = #"(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?\s*(?:to|[–−-])\s*(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let startHour = piece(text, match, 1).flatMap(Int.init),
              let startMinute = piece(text, match, 2).flatMap(Int.init),
              let endHour = piece(text, match, 4).flatMap(Int.init),
              let endMinute = piece(text, match, 5).flatMap(Int.init),
              let start = hour(startHour, piece(text, match, 3)),
              let end = hour(endHour, piece(text, match, 6) ?? piece(text, match, 3)) else { return nil }
        guard (0..<60).contains(startMinute), (0..<60).contains(endMinute) else { return nil }
        return (start, startMinute, end, endMinute)
    }

    private static func piece(_ text: String, _ match: NSTextCheckingResult, _ index: Int) -> String? {
        guard match.range(at: index).location != NSNotFound, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func hour(_ value: Int, _ ampm: String?) -> Int? {
        guard let ampm else { return (0...23).contains(value) ? value : nil }
        let afternoon = ampm.lowercased().hasPrefix("p")
        guard (1...12).contains(value) else { return nil }
        if value == 12 { return afternoon ? 12 : 0 }
        return afternoon ? value + 12 : value
    }
}

/// Days already read stay when a later read only shows another day.
struct BrowserEventMemory: Equatable {
    private var byDay: [Date: [CalendarMeeting]] = [:]

    mutating func replace(_ meetings: [CalendarMeeting], calendar: Calendar = .current) {
        for (day, rows) in Dictionary(grouping: meetings, by: { calendar.startOfDay(for: $0.start) }) {
            byDay[day] = rows.sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
        }
    }

    /// A read that ran out of time adds the rows it reached and leaves the rest in place.
    mutating func add(_ meetings: [CalendarMeeting], calendar: Calendar = .current) {
        for (day, rows) in Dictionary(grouping: meetings, by: { calendar.startOfDay(for: $0.start) }) {
            var existing = byDay[day] ?? []
            let seen = Set(existing.map(\.id))
            existing.append(contentsOf: rows.filter { !seen.contains($0.id) })
            byDay[day] = existing.sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
        }
    }

    mutating func restore(_ meetings: [CalendarMeeting], calendar: Calendar = .current) {
        byDay.removeAll()
        replace(meetings, calendar: calendar)
    }

    func stored() -> [CalendarMeeting] { overlapping(from: .distantPast, to: .distantFuture) }

    func overlapping(from: Date, to: Date) -> [CalendarMeeting] {
        byDay.values.flatMap { $0 }.filter { $0.start < to && $0.end > from }
            .sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
    }

    mutating func clear() { byDay.removeAll() }
}
