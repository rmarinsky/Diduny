import AppKit
import Foundation

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

/// Which meeting occurrences were reminded, joined, dismissed or snoozed.
/// `shown` is per app session, so a running meeting is offered again after relaunch, wake or unlock.
struct CalendarReminderLedger: Codable, Equatable {
    private var delivered: [String: Date] = [:]
    private var acknowledged: [String: Date] = [:]
    private var snoozed: [String: Date] = [:]
    private var shown: Set<String> = []

    private enum CodingKeys: String, CodingKey { case delivered, acknowledged, snoozed }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delivered = try container.decodeIfPresent([String: Date].self, forKey: .delivered) ?? [:]
        acknowledged = try container.decodeIfPresent([String: Date].self, forKey: .acknowledged) ?? [:]
        snoozed = try container.decodeIfPresent([String: Date].self, forKey: .snoozed) ?? [:]
    }

    /// Editing the event in Calendar changes the key, so a dismissed meeting is offered again.
    static func acknowledgementKey(_ meeting: CalendarMeeting) -> String {
        meeting.reminderKey + "|" + (meeting.lastModified.map { String($0.timeIntervalSince1970) } ?? "")
    }

    func isAcknowledged(_ meeting: CalendarMeeting) -> Bool { acknowledged[Self.acknowledgementKey(meeting)] != nil }
    mutating func acknowledge(_ meeting: CalendarMeeting, at now: Date) { acknowledged[Self.acknowledgementKey(meeting)] = now }
    mutating func snooze(_ meeting: CalendarMeeting, until date: Date) {
        let key = Self.acknowledgementKey(meeting)
        snoozed[key] = date
        shown.remove(key)
    }
    mutating func resetSession() { shown = [] }

    mutating func due(_ meetings: [CalendarMeeting], selected: Set<String>, now: Date,
                      fetchedAt: Date?, leadMinutes: Int, repeatDuringMeeting: Bool = false) -> [CalendarMeeting] {
        let dayAgo = now.addingTimeInterval(-86400)
        delivered = delivered.filter { $0.value > dayAgo }
        acknowledged = acknowledged.filter { $0.value > dayAgo }
        snoozed = snoozed.filter { $0.value > dayAgo }
        guard let fetchedAt, now.timeIntervalSince(fetchedAt) >= 0,
              now.timeIntervalSince(fetchedAt) <= 300 else { return [] }
        let lead = now.addingTimeInterval(TimeInterval(max(0, leadMinutes) * 60))
        return meetings.filter { selected.contains($0.calendarID) && $0.canRemind && $0.end > now }
            .sorted { $0.start < $1.start }
            .filter { meeting in
                let key = Self.acknowledgementKey(meeting)
                guard acknowledged[key] == nil, !shown.contains(key) else { return false }
                if let until = snoozed[key] {
                    guard until <= now else { return false }
                    snoozed[key] = nil
                } else {
                    let upcoming = meeting.start >= now.addingTimeInterval(-300) && meeting.start <= lead
                        && delivered[meeting.reminderKey] == nil
                    let running = repeatDuringMeeting && meeting.start <= now
                    guard upcoming || running else { return false }
                }
                delivered[meeting.reminderKey] = now
                shown.insert(key)
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

    /// "Starts in 4 min", "Starting now" or "Started 6 min ago · ends 16:30".
    func statusLine(now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds >= 60 { return String(localized: "Starts in \(Int((seconds / 60).rounded(.up))) min") }
        if seconds > -60 { return String(localized: "Starting now") }
        let minutes = Int((-seconds / 60).rounded(.down))
        return String(localized: "Started \(minutes) min ago · ends \(end.formatted(date: .omitted, time: .shortened))")
    }

    /// "Google Meet · 16:00 – 16:30 (30 min)"
    var scheduleLine: String {
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        let time = start.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
            + " " + String(localized: "(\(minutes) min)")
        return [Self.serviceName(for: meetingURL), time].compactMap { $0 }.joined(separator: " · ")
    }

    static func attendeeSummary(_ attendees: [CalendarAttendee]) -> String {
        let count = { (response: CalendarAttendee.Response) in attendees.filter { $0.response == response }.count }
        let waiting = count(.pending) + count(.unknown)
        return ([String(localized: "\(attendees.count) people")]
            + (count(.accepted) > 0 ? [String(localized: "\(count(.accepted)) accepted")] : [])
            + (count(.tentative) > 0 ? [String(localized: "\(count(.tentative)) maybe")] : [])
            + (count(.declined) > 0 ? [String(localized: "\(count(.declined)) declined")] : [])
            + (waiting > 0 ? [String(localized: "\(waiting) no response")] : []))
            .joined(separator: " · ")
    }

    /// Opens the event in Calendar.
    var calendarAppURL: URL? {
        guard let identifier = eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "ical://ekevent/\(identifier)?method=show&options=more")
    }

    static func copyLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    static func serviceName(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        if host == "meet.google.com" { return "Google Meet" }
        if host.hasPrefix("teams.") { return "Microsoft Teams" }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Zoom" }
        if host == "webex.com" || host.hasSuffix(".webex.com") { return "Webex" }
        if host == "meet.jit.si" { return "Jitsi Meet" }
        if host == "app.slack.com" { return "Slack huddle" }
        if host == "facetime.apple.com" { return "FaceTime" }
        if host == "whereby.com" { return "Whereby" }
        if host == "chime.aws" { return "Amazon Chime" }
        return nil
    }

    enum OpenTarget: Equatable {
        case app(URL)
        case browser(URL, bundleID: String?)
    }

    /// Zoom and Teams open in their apps when asked and installed; everything else in the chosen browser.
    static func openTarget(for url: URL, configuration: CalendarConfiguration, appInstalled: (URL) -> Bool) -> OpenTarget {
        if configuration.openInApps, let app = appURL(for: url), appInstalled(app) { return .app(app) }
        return .browser(url, bundleID: configuration.browserBundleID)
    }

    /// The desktop-app form of a Zoom or Teams meeting link. Personal Zoom rooms have no app form.
    static func appURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            let parts = url.path.split(separator: "/")
            guard parts.count >= 2, parts[0] == "j" else { return nil }
            var components = URLComponents()
            components.scheme = "zoommtg"
            components.host = "zoom.us"
            components.path = "/join"
            var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(parts[1]))]
            if let password = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "pwd" })?.value {
                items.append(URLQueryItem(name: "pwd", value: password))
            }
            components.queryItems = items
            return components.url
        }
        if host == "teams.microsoft.com", url.path.hasPrefix("/l/meetup-join/") || url.path.hasPrefix("/meet/") {
            let link = url.absoluteString
            guard let hostRange = link.range(of: "teams.microsoft.com", options: .caseInsensitive) else { return nil }
            return URL(string: "msteams:" + link[hostRange.upperBound...])
        }
        return nil
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
        if host == "app.slack.com" { return path.hasPrefix("/huddle/") }
        if host == "facetime.apple.com" { return path.hasPrefix("/join") }
        if host == "whereby.com" { return path.range(of: "^/[A-Za-z0-9][A-Za-z0-9-]*$", options: .regularExpression) != nil }
        if host == "chime.aws" { return path.range(of: "^/[0-9]{10}$", options: .regularExpression) != nil }
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
    struct Segment: Equatable, Identifiable { let id: String; let from: Double; let to: Double; let phase: Phase; var title = "" }

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
            .map { Segment(id: $0.id, from: position($0.start), to: position($0.end), phase: $0.phase(at: now), title: $0.title) }
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

enum CalendarRecordingMatch: Equatable {
    case none
    case linked(CalendarMeeting)
    case ambiguous([CalendarMeeting])
}

extension CalendarMeeting {
    /// The event a recording belongs to. An event fits when it covers at least half of the recording
    /// or the recording covers at least half of it; two fits within 20 points of each other are ambiguous.
    static func match(recordingStart: Date, recordingEnd: Date, events: [CalendarMeeting]) -> CalendarRecordingMatch {
        let length = recordingEnd.timeIntervalSince(recordingStart)
        guard length > 0 else { return .none }
        let scored = events.filter { !$0.allDay && !$0.cancelled && !$0.declined && $0.end > $0.start }
            .compactMap { event -> (event: CalendarMeeting, score: Double)? in
                let overlap = min(recordingEnd, event.end).timeIntervalSince(max(recordingStart, event.start))
                guard overlap > 0 else { return nil }
                let score = max(overlap / length, overlap / event.end.timeIntervalSince(event.start))
                return score >= 0.5 ? (event, score) : nil
            }
            .sorted { $0.score > $1.score }
        guard let best = scored.first else { return .none }
        let close = scored.filter { best.score - $0.score < 0.2 }.map(\.event)
        return close.count == 1 ? .linked(best.event) : .ambiguous(close.sorted { $0.start < $1.start })
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
