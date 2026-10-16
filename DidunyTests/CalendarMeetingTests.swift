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
                     "javascript:alert(1)", "https://localhost/meeting", "http://zoom.us/j/123", "https://zoom.us/", "https://zoom.us/privacy",
                     "https://teams.microsoft.com/meetingOptions/?token=test", "https://meet.google.com/"] {
            XCTAssertNil(CalendarMeeting.joinURL(in: text), text)
        }
    }

    func testPendingRemindersMergeStaggeredOccurrencesAndPruneRemovedEvents() {
        let now = Date()
        let a = CalendarMeeting(id: "a", calendarID: "work", title: "A", start: now, end: now.addingTimeInterval(600))
        let b = CalendarMeeting(id: "b", calendarID: "work", title: "B", start: now.addingTimeInterval(15), end: now.addingTimeInterval(900))
        XCTAssertEqual(CalendarMeeting.pendingReminders(existing: [a], incoming: [b], current: [a, b]), [a, b])
        XCTAssertEqual(CalendarMeeting.pendingReminders(existing: [a], incoming: [b], current: [b]), [b])
    }

    @MainActor func testIncomingReminderKeepsExplicitRecordingOptOut() {
        let state = CalendarReminderPresentation()
        state.prepare(defaultRecord: true, replacingVisible: false)
        XCTAssertTrue(state.record)
        state.record = false
        state.prepare(defaultRecord: true, replacingVisible: true)
        XCTAssertFalse(state.record)
        state.prepare(defaultRecord: true, replacingVisible: false)
        XCTAssertTrue(state.record)
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

    func testJoinDoesNotToggleAnActiveRecordingAndNeverRecordsIfOpeningFails() {
        XCTAssertEqual(CalendarJoinDecision.resolve(record: false, openingSucceeded: true,
                        alreadyRecording: false, busy: false), .joinOnly)
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                        alreadyRecording: true, busy: false), .linkExisting)
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                        alreadyRecording: false, busy: true), .recordingUnavailable)
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: false,
                        alreadyRecording: false, busy: false), .openFailed)
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                        alreadyRecording: false, busy: false), .startRecording)
    }

}
