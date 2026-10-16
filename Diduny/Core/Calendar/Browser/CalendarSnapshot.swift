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
        case .consentRequired: return "Approve this read before accessing the calendar."
        case .wrongPage: return "Select a Google Calendar or Outlook Calendar tab in the chosen browser, then retry."
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
