import Foundation

public enum CalendarProvider: String, Sendable { case google = "Google Calendar", microsoft = "Microsoft Outlook" }

public enum CalendarPage {
    public static func provider(for url: URL) -> CalendarProvider? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              url.path == "/calendar" || url.path.hasPrefix("/calendar/") else { return nil }
        switch url.host?.lowercased() {
        case "calendar.google.com": return .google
        case "outlook.cloud.microsoft", "outlook.office.com", "outlook.office365.com", "outlook.live.com": return .microsoft
        default: return nil
        }
    }
}
