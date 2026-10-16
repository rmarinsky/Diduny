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
    func testJoinLinksRejectCredentialsLookalikeHostsAndNonWebSchemes() {
        XCTAssertEqual(CalendarMeeting.joinURL(in: "Join https://meet.google.com/abc-defg-hij"),
                       URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertNotNil(CalendarMeeting.joinURL(in: "https://teams.microsoft.com/l/meetup-join/meeting?context=test"))
        for text in ["https://meet.google.com.evil.test/abc", "https://user:password@meet.google.com/abc",
                     "javascript:alert(1)", "https://localhost/meeting", "http://zoom.us/j/123"] {
            XCTAssertNil(CalendarMeeting.joinURL(in: text), text)
        }
    }

    func testDeliveredReminderSurvivesRestartAndIgnoresAllDayDeclinedAndEnded() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var event = CalendarMeeting(id: "event", calendarID: "work", title: "Review",
                                    start: now, end: now.addingTimeInterval(1800))
        var ledger = CalendarReminderLedger()
        XCTAssertEqual(ledger.due([event], selected: ["work"], now: now, fetchedAt: now, leadMinutes: 0).count, 1)
        var restored = try JSONDecoder().decode(CalendarReminderLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertTrue(restored.due([event], selected: ["work"], now: now, fetchedAt: now, leadMinutes: 0).isEmpty)
        var fresh = CalendarReminderLedger()
        event.allDay = true
        XCTAssertTrue(fresh.due([event], selected: ["work"], now: now, fetchedAt: now, leadMinutes: 0).isEmpty)
        event.allDay = false; event.declined = true
        XCTAssertTrue(fresh.due([event], selected: ["work"], now: now, fetchedAt: now, leadMinutes: 0).isEmpty)
        event.declined = false; event.end = now
        XCTAssertTrue(fresh.due([event], selected: ["work"], now: now, fetchedAt: now, leadMinutes: 0).isEmpty)
    }

}
