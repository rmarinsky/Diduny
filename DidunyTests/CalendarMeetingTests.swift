@testable import Diduny
import XCTest

final class CalendarMeetingTests: XCTestCase {
    func testReminderUsesOccurrenceAndStartTimeAndRejectsStaleOrCancelledEvents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(id: "account/event/occurrence", calendarID: "work", title: "Review",
                                      start: now.addingTimeInterval(300), end: now.addingTimeInterval(1800),
                                      meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        var reminders = CalendarReminderLedger()
        XCTAssertEqual(reminders.due([meeting], selected: ["work"], now: now,
                                    fetchedAt: now, leadMinutes: 15).map(\.id), [meeting.id])
        XCTAssertTrue(reminders.due([meeting], selected: ["work"], now: now,
                                   fetchedAt: now, leadMinutes: 15).isEmpty)
        var moved = meeting
        moved.start = now.addingTimeInterval(600)
        XCTAssertEqual(reminders.due([moved], selected: ["work"], now: now,
                                    fetchedAt: now, leadMinutes: 15).count, 1)
        moved.start = now.addingTimeInterval(700)
        moved.cancelled = true
        XCTAssertTrue(reminders.due([moved], selected: ["work"], now: now,
                                   fetchedAt: now, leadMinutes: 15).isEmpty)
        var freshLedger = CalendarReminderLedger()
        XCTAssertTrue(freshLedger.due([meeting], selected: ["work"], now: now,
                                     fetchedAt: now.addingTimeInterval(-301), leadMinutes: 15).isEmpty)
        XCTAssertTrue(freshLedger.due([meeting], selected: [], now: now,
                                     fetchedAt: now, leadMinutes: 15).isEmpty)
    }
}
