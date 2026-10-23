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

    func testTeamsLinkStopsBeforeAdjacentOutlookSafeLinksWithoutChangingJoinParameters() {
        let teams = "https://teams.microsoft.com/meet/123456789?p=ExamplePasscode"
        let safe = "https://eur02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fmeet%2F123456789%3Fp%3DExamplePasscode&data=synthetic"
        for text in ["Join \(teams)<\(safe)>", "\(teams)%3C\(safe)%3E", "\(teams)&lt;\(safe)&gt;"] {
            XCTAssertEqual(CalendarMeeting.joinURL(in: text)?.absoluteString, teams)
        }
        let legacy = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_example%40thread.v2/0?context=%7B%22Tid%22%3A%22example%22%7D&anon=true"
        XCTAssertEqual(CalendarMeeting.joinURL(in: legacy)?.absoluteString, legacy)
        let encodedContext = "https://teams.microsoft.com/meet/123?context=%3Chttps://example.com%3E"
        XCTAssertEqual(CalendarMeeting.joinURL(in: encodedContext)?.absoluteString, encodedContext)
        XCTAssertNil(CalendarMeeting.joinURL(in: "https://eur02.safelinks.protection.outlook.com/?url=%3Chttps://teams.microsoft.com/meet/123%3E"))
        XCTAssertNil(CalendarMeeting.joinURL(in: safe))
        XCTAssertNil(CalendarMeeting.joinURL(in: "https://teams.microsoft.com.evil.test/meet/123<\(safe)>"))
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

    func testCalendarJoinKeepsMeetingInFrontAndOnlyShowsAccountForInPersonRecording() {
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                       alreadyRecording: false, busy: false, isSignedIn: false), .signInRequired(showAccount: false))
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                       alreadyRecording: false, busy: false, isSignedIn: false, hasMeetingURL: false), .signInRequired(showAccount: true))
        XCTAssertEqual(CalendarJoinDecision.resolve(record: false, openingSucceeded: true,
                       alreadyRecording: false, busy: false, isSignedIn: false), .joinOnly)
    }

    func testInPersonCalendarRecordingStillOpensTheLibrary() {
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                        alreadyRecording: false, busy: false, hasMeetingURL: false), .startRecording(showLibrary: true))
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                        alreadyRecording: true, busy: false, hasMeetingURL: false), .linkExisting(showLibrary: true))
    }

    func testJoinDoesNotToggleAnActiveRecordingAndNeverRecordsIfOpeningFails() {
        XCTAssertEqual(CalendarJoinDecision.resolve(record: false, openingSucceeded: true,
                        alreadyRecording: false, busy: false), .joinOnly)
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                        alreadyRecording: true, busy: false), .linkExisting(showLibrary: false))
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                        alreadyRecording: false, busy: true), .recordingUnavailable)
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: false,
                        alreadyRecording: false, busy: false), .openFailed)
        XCTAssertEqual(CalendarJoinDecision.resolve(record: true, openingSucceeded: true,
                        alreadyRecording: false, busy: false), .startRecording(showLibrary: false))
    }

    func testAgendaShowsAllOfTodayIncludingEndedMeetingsThenTomorrowWithoutDuplicates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        let at = { (day: Int, hour: Int, minute: Int) in
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let now = at(23, 12, 53)
        let event = { (id: String, start: Date, end: Date) in
            CalendarMeeting(id: id, calendarID: "work", title: id, start: start, end: end)
        }
        let ended = event("tennis", at(23, 9, 0), at(23, 10, 0))
        let next = event("ba", at(23, 16, 0), at(23, 16, 30))
        let overnight = event("release", at(23, 23, 30), at(24, 0, 30))
        let tomorrow = event("standup", at(24, 10, 0), at(24, 10, 15))
        var declined = event("declined", at(23, 14, 0), at(23, 15, 0)); declined.declined = true
        var allDay = event("holiday", at(23, 0, 0), at(24, 0, 0)); allDay.allDay = true
        let later = event("later", at(25, 10, 0), at(25, 11, 0))

        let agenda = CalendarMeeting.agenda([tomorrow, later, next, overnight, declined, allDay, ended],
                                            now: now, calendar: calendar)
        XCTAssertEqual(agenda.map(\.day), [at(23, 0, 0), at(24, 0, 0)])
        XCTAssertEqual(agenda.map { $0.meetings.map(\.id) }, [["tennis", "ba", "release"], ["standup"]])
        XCTAssertEqual(ended.phase(at: now), .past)
        XCTAssertEqual(next.phase(at: now), .upcoming)
        XCTAssertEqual(event("now", at(23, 12, 30), at(23, 13, 0)).phase(at: now), .current)
        XCTAssertTrue(CalendarMeeting.agenda([later, ended], now: at(26, 8, 0), calendar: calendar).isEmpty)
    }

    func testTimelineShowsEightHoursFromTwoHoursBeforeNowAndClipsMeetingsToIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        let at = { (hour: Int, minute: Int) in
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: hour, minute: minute))!
        }
        let event = { (id: String, start: Date, end: Date) in
            CalendarMeeting(id: id, calendarID: "work", title: id, start: start, end: end)
        }
        var cancelled = event("cancelled", at(15, 0), at(15, 30)); cancelled.cancelled = true
        let timeline = CalendarTimeline(meetings: [
            event("qa", at(17, 0), at(19, 0)), event("tennis", at(9, 0), at(10, 30)),
            event("sync", at(11, 30), at(11, 45)), event("current", at(12, 30), at(13, 30)),
            event("tomorrow", at(19, 0), at(20, 0)), cancelled
        ], now: at(12, 53), calendar: calendar)

        XCTAssertEqual(timeline.hours.map(\.hour), Array(10...18))
        XCTAssertEqual(timeline.hours.first?.position, 0)
        XCTAssertEqual(timeline.hours.last?.position, 1)
        XCTAssertEqual(timeline.now, (2 * 60 + 53) / 480.0, accuracy: 0.0001)
        XCTAssertEqual(timeline.segments.map(\.id), ["tennis", "sync", "current", "qa"])
        XCTAssertEqual(timeline.segments.map(\.phase), [.past, .past, .current, .upcoming])
        XCTAssertEqual(timeline.segments.first?.from, 0, "Meetings before the window are clipped")
        XCTAssertEqual(timeline.segments.last?.to, 1, "Meetings after the window are clipped")
        XCTAssertEqual(timeline.segments[1].from, 90 / 480.0, accuracy: 0.0001)
    }
}
