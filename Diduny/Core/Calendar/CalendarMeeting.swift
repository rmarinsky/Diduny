import Foundation

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
