import Foundation
import Observation

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

extension CalendarMeeting {
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
