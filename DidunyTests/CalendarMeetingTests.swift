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
        XCTAssertEqual(timeline.lanes, 1)
    }

    func testTimelinePutsOverlappingMeetingsInSeparateLanes() {
        let calendar = Calendar(identifier: .gregorian)
        let at = { (hour: Int, minute: Int) in
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: hour, minute: minute))!
        }
        let event = { (id: String, start: Date, end: Date) in
            CalendarMeeting(id: id, calendarID: "work", title: id, start: start, end: end)
        }
        let timeline = CalendarTimeline(meetings: [
            event("a", at(11, 0), at(12, 0)), event("b", at(11, 30), at(12, 30)),
            event("c", at(11, 45), at(12, 15)), event("d", at(12, 0), at(13, 0)), event("e", at(13, 0), at(14, 0))
        ], now: at(12, 0), calendar: calendar)

        XCTAssertEqual(timeline.segments.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(timeline.segments.map(\.lane), [0, 1, 2, 0, 0], "Back-to-back meetings reuse the freed lane")
        XCTAssertEqual(timeline.lanes, 3)
    }

    func testAgendaNotesDropMarkupAndJoinBoilerplate() {
        let notes = """
        <p>Agenda:<br>1. Pilot scope<br/>2. Metrics &amp; owners</p>
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join on your computer, mobile app or room device
        """
        XCTAssertEqual(CalendarMeeting.cleanedNotes(notes), "Agenda:\n1. Pilot scope\n2. Metrics & owners")
        XCTAssertEqual(CalendarMeeting.cleanedNotes("Review\n\n\n\nJoin Zoom Meeting\nhttps://zoom.us/j/1"), "Review")
        XCTAssertEqual(CalendarMeeting.cleanedNotes("Notes\n-::~:~::~:~:~::~:~::-\nJoin with Google Meet"), "Notes")
        XCTAssertNil(CalendarMeeting.cleanedNotes("  \n<br>  "))
        XCTAssertNil(CalendarMeeting.cleanedNotes(nil))
    }

    func testAgendaNotesKeepPlainTextInAngleBrackets() {
        XCTAssertEqual(CalendarMeeting.cleanedNotes("Host: Jane Doe <jane@example.com>\nDeck <https://example.com/deck>"),
                       "Host: Jane Doe <jane@example.com>\nDeck <https://example.com/deck>")
        XCTAssertEqual(CalendarMeeting.cleanedNotes(#"<div class="x"><b>Agenda</b> <a href="https://a.b">deck</a></div>"#), "Agenda deck")
    }

    func testFindingAnEventTellsAFailedCalendarReadFromNoOverlap() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000), end = start.addingTimeInterval(1800)
        let review = CalendarMeeting(id: "r", calendarID: "work", title: "Review", start: start, end: end)
        let later = CalendarMeeting(id: "l", calendarID: "work", title: "Later", start: end.addingTimeInterval(7200), end: end.addingTimeInterval(9000))
        struct Denied: Error {}

        let found = await CalendarMeeting.findEvents(recordingStart: start, recordingEnd: end) { _, _ in [review, later] }
        XCTAssertEqual(found, .found([review]))
        let none = await CalendarMeeting.findEvents(recordingStart: start, recordingEnd: end) { _, _ in [later] }
        XCTAssertEqual(none, .noOverlap)
        let failed = await CalendarMeeting.findEvents(recordingStart: start, recordingEnd: end) { _, _ in throw Denied() }
        XCTAssertEqual(failed, .readFailed)
    }

    func testRecordCurrentMeetingReportsStartOnlyWhenTheRecordingStarted() {
        XCTAssertTrue(RecordCurrentMeetingIntent.started(after: .processing))
        XCTAssertTrue(RecordCurrentMeetingIntent.started(after: .recording))
        XCTAssertFalse(RecordCurrentMeetingIntent.started(after: .idle), "Signed out or another recording blocked the start")
    }

    func testStoredMeetingsWithoutEventDetailsStillDecodeAndDetailsRoundTrip() throws {
        let legacy = #"{"id":"a","calendarID":"work","title":"Review","start":0,"end":600,"cancelled":false,"declined":false,"allDay":false}"#
        let decoded = try JSONDecoder().decode(CalendarMeeting.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.title, "Review")
        XCTAssertNil(decoded.attendees)
        XCTAssertNil(decoded.notes)

        var meeting = decoded
        meeting.notes = "Agenda"
        meeting.location = "Room 4"
        meeting.calendarTitle = "Work"
        meeting.calendarColorRGB = 0x4285F4
        meeting.myResponse = .tentative
        meeting.attendees = [
            CalendarAttendee(name: "Olena Kovalenko", email: "olena.k@neovolta.com", response: .accepted, isOrganizer: true),
            CalendarAttendee(name: nil, email: "mark@neovolta.com", response: .declined),
        ]
        let restored = try JSONDecoder().decode(CalendarMeeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(restored, meeting)
        XCTAssertEqual(restored.organizer?.displayName, "Olena Kovalenko")
        XCTAssertEqual(restored.attendees?.last?.displayName, "mark@neovolta.com")
    }

    func testRunningMeetingIsShownAgainUntilJoinedOrDismissedAndSnoozeDelaysIt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var meeting = CalendarMeeting(id: "m", calendarID: "work", title: "Review",
                                      start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200),
                                      meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        var ledger = CalendarReminderLedger()
        let due = { (ledger: inout CalendarReminderLedger, at: Date) in
            ledger.due([meeting], selected: ["work"], now: at, fetchedAt: at, leadMinutes: 0, repeatDuringMeeting: true).map(\.id)
        }
        XCTAssertTrue(ledger.due([meeting], selected: ["work"], now: now, fetchedAt: now, leadMinutes: 0).isEmpty,
                      "Without the setting a meeting that started 10 minutes ago is not shown")
        XCTAssertEqual(due(&ledger, now), ["m"])
        XCTAssertEqual(due(&ledger, now), [], "Shown once per session")
        var restored = try JSONDecoder().decode(CalendarReminderLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(due(&restored, now), ["m"], "Shown again after relaunch while not joined or dismissed")
        ledger.resetSession()
        XCTAssertEqual(due(&ledger, now), ["m"], "Shown again after wake or unlock")

        ledger.snooze(meeting, until: now.addingTimeInterval(60))
        XCTAssertEqual(due(&ledger, now.addingTimeInterval(30)), [])
        XCTAssertEqual(due(&ledger, now.addingTimeInterval(61)), ["m"])

        ledger.acknowledge(meeting, at: now)
        ledger.resetSession()
        XCTAssertEqual(due(&ledger, now.addingTimeInterval(90)), [], "Joined or dismissed meetings stay quiet")
        restored = try JSONDecoder().decode(CalendarReminderLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(due(&restored, now.addingTimeInterval(90)), [])
        meeting.lastModified = now
        XCTAssertEqual(due(&ledger, now.addingTimeInterval(90)), [], "An RSVP or note edit does not re-arm a dismissed meeting")
        meeting.meetingURL = URL(string: "https://meet.google.com/xyz-abcd-efg")
        XCTAssertEqual(due(&ledger, now.addingTimeInterval(90)), ["m"], "A new link re-arms it")

        var focus = CalendarMeeting(id: "focus", calendarID: "work", title: "Focus time",
                                    start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3600))
        var fresh = CalendarReminderLedger()
        XCTAssertTrue(fresh.due([focus], selected: ["work"], now: now, fetchedAt: now, leadMinutes: 0, repeatDuringMeeting: true).isEmpty,
                      "Blocks without a link or attendees are not offered again while running")
        focus.attendees = [CalendarAttendee(name: "Olena", email: "olena@example.com")]
        XCTAssertEqual(fresh.due([focus], selected: ["work"], now: now, fetchedAt: now, leadMinutes: 0, repeatDuringMeeting: true).map(\.id), ["focus"])
    }

    func testSavedCalendarSettingsWithoutNewKeysKeepTheirValues() throws {
        let saved = #"{"version":1,"connected":true,"selected":["work"],"displayMinutes":15,"reminderMinutes":5,"popup":true,"fullScreen":false,"recordOnJoin":true,"localRecording":false,"ledger":{"delivered":{}}}"#
        let configuration = try JSONDecoder().decode(CalendarConfiguration.self, from: Data(saved.utf8))
        XCTAssertTrue(configuration.connected)
        XCTAssertEqual(configuration.selected, ["work"])
        XCTAssertEqual(configuration.reminderMinutes, 5)
        XCTAssertEqual(configuration.reminderStyle, .window)
        XCTAssertTrue(configuration.recordOnJoin)
        XCTAssertTrue(configuration.repeatDuringMeeting)
        let odd = #"{"connected":true,"reminderMinutes":30,"displayMinutes":120}"#
        let snapped = try JSONDecoder().decode(CalendarConfiguration.self, from: Data(odd.utf8))
        XCTAssertEqual(snapped.reminderMinutes, 15, "Older values outside the picker snap to the nearest choice")
        XCTAssertEqual(snapped.displayMinutes, 60)
        let fresh = CalendarConfiguration()
        XCTAssertEqual(fresh.reminderStyle, .fullScreen)
        XCTAssertEqual(fresh.reminderMinutes, 5)
        XCTAssertTrue(fresh.recordOnJoin)
        XCTAssertTrue(fresh.localRecording)
    }

    func testOlderSettingsGetTheHeadsUpAndRecordOnJoinOnceButKeepLaterChoices() throws {
        let old = #"{"version":1,"connected":true,"reminderMinutes":0,"recordOnJoin":false,"popup":false,"fullScreen":false}"#
        let migrated = try JSONDecoder().decode(CalendarConfiguration.self, from: Data(old.utf8))
        XCTAssertEqual(migrated.reminderMinutes, 5)
        XCTAssertTrue(migrated.recordOnJoin)
        XCTAssertEqual(migrated.reminderStyle, .off, "A start reminder turned off stays off")

        var chosen = migrated
        chosen.reminderMinutes = 0
        chosen.recordOnJoin = false
        let restored = try JSONDecoder().decode(CalendarConfiguration.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(restored.reminderMinutes, 0, "Turning the heads-up off after the update is kept")
        XCTAssertFalse(restored.recordOnJoin)
    }

    func testHeadsUpComesOnceBeforeTheStartAndDismissingItKeepsTheStartReminder() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(id: "m", calendarID: "work", title: "Review",
                                      start: now.addingTimeInterval(240), end: now.addingTimeInterval(2040),
                                      meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        var ledger = CalendarReminderLedger()
        let early = { (ledger: inout CalendarReminderLedger, at: Date, lead: Int) in
            ledger.dueEarly([meeting], selected: ["work"], now: at, fetchedAt: at, leadMinutes: lead).map(\.id)
        }
        XCTAssertEqual(early(&ledger, now.addingTimeInterval(-120), 5), [], "Not before the lead time")
        XCTAssertEqual(early(&ledger, now, 0), [], "Off")
        XCTAssertEqual(early(&ledger, now, 5), ["m"])
        XCTAssertEqual(early(&ledger, now.addingTimeInterval(30), 5), [], "Once per occurrence")
        let restored = try JSONDecoder().decode(CalendarReminderLedger.self, from: JSONEncoder().encode(ledger))
        var copy = restored
        XCTAssertEqual(early(&copy, now.addingTimeInterval(30), 5), [], "Also after relaunch")
        XCTAssertEqual(ledger.due([meeting], selected: ["work"], now: meeting.start, fetchedAt: meeting.start, leadMinutes: 0).map(\.id),
                       ["m"], "The start reminder still comes after the heads-up")

        var late = CalendarReminderLedger()
        XCTAssertEqual(early(&late, meeting.start.addingTimeInterval(-59), 5), [],
                       "Less than a minute before the start only the start reminder comes")
        var joined = CalendarReminderLedger()
        joined.acknowledge(meeting, at: now)
        XCTAssertEqual(early(&joined, now, 5), [], "Joined already")
    }

    func testMeetingServiceNamesComeFromTheJoinLink() {
        let name = { (link: String) in CalendarMeeting.serviceName(for: URL(string: link)) }
        XCTAssertEqual(name("https://meet.google.com/abc-defg-hij"), "Google Meet")
        XCTAssertEqual(name("https://teams.microsoft.com/l/meetup-join/x"), "Microsoft Teams")
        XCTAssertEqual(name("https://acme.zoom.us/j/123"), "Zoom")
        XCTAssertEqual(name("https://acme.webex.com/meet/x"), "Webex")
        XCTAssertNil(name("https://example.com/x"))
    }

    func testMeetingNowStatusAndAttendeeSummary() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(id: "m", calendarID: "work", title: "Review", start: start, end: start.addingTimeInterval(1800),
                                      meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(meeting.statusLine(now: start.addingTimeInterval(-170)), String(localized: "Starts in \(3) min"))
        XCTAssertEqual(meeting.statusLine(now: start.addingTimeInterval(20)), String(localized: "Starting now"))
        XCTAssertEqual(meeting.statusLine(now: start.addingTimeInterval(400)), String(localized: "Started \(6) min ago · ends \(meeting.end.formatted(date: .omitted, time: .shortened))"))
        XCTAssertTrue(meeting.scheduleLine.hasPrefix("Google Meet · "))
        XCTAssertTrue(meeting.scheduleLine.hasSuffix(" " + String(localized: "(\(30) min)")))
        XCTAssertEqual(CalendarMeeting.attendeeSummary([
            CalendarAttendee(name: "A", response: .accepted), CalendarAttendee(name: "B", response: .accepted),
            CalendarAttendee(name: "C", response: .declined), CalendarAttendee(name: "D", response: .pending),
            CalendarAttendee(name: "E"),
        ]), [String(localized: "\(5) people"), String(localized: "\(2) accepted"), String(localized: "\(1) declined"),
            String(localized: "\(2) no response")].joined(separator: " · "))
    }

    func testMoreMeetingServicesAreRecognizedWithoutLookalikes() {
        for link in ["https://app.slack.com/huddle/T0123ABCD/C0456EFGH", "https://facetime.apple.com/join#v=1&p=AbCdEf&k=xyz",
                     "https://whereby.com/team-standup", "https://chime.aws/1234567890"] {
            XCTAssertEqual(CalendarMeeting.joinURL(in: "Join: \(link)")?.absoluteString, link, link)
        }
        for link in ["https://app.slack.com/client/T0123ABCD", "https://whereby.com/", "https://whereby.com/information/pricing",
                     "https://chime.aws/", "https://facetime.apple.com/", "https://whereby.com.evil.test/room"] {
            XCTAssertNil(CalendarMeeting.joinURL(in: link), link)
        }
        XCTAssertEqual(CalendarMeeting.serviceName(for: URL(string: "https://app.slack.com/huddle/T1/C2")), "Slack huddle")
        XCTAssertEqual(CalendarMeeting.serviceName(for: URL(string: "https://facetime.apple.com/join#v=1")), "FaceTime")
    }

    func testZoomAndTeamsLinksOpenInTheirAppsOnlyWhenRequested() {
        let zoom = URL(string: "https://acme.zoom.us/j/123456789?pwd=AbC12")!
        XCTAssertEqual(CalendarMeeting.appURL(for: zoom)?.absoluteString, "zoommtg://zoom.us/join?action=join&confno=123456789&pwd=AbC12")
        XCTAssertEqual(CalendarMeeting.appURL(for: URL(string: "https://zoom.us/j/987")!)?.absoluteString,
                       "zoommtg://zoom.us/join?action=join&confno=987")
        XCTAssertNil(CalendarMeeting.appURL(for: URL(string: "https://zoom.us/my/roman")!), "Personal rooms stay in the browser")
        let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7B%7D")!
        XCTAssertEqual(CalendarMeeting.appURL(for: teams)?.absoluteString, "msteams:/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7B%7D")
        XCTAssertNil(CalendarMeeting.appURL(for: URL(string: "https://meet.google.com/abc-defg-hij")!))

        var configuration = CalendarConfiguration()
        XCTAssertEqual(CalendarMeeting.openTarget(for: zoom, configuration: configuration, appInstalled: { _ in true }), .browser(zoom, bundleID: nil))
        configuration.openInApps = true
        configuration.browserBundleID = "com.google.Chrome"
        XCTAssertEqual(CalendarMeeting.openTarget(for: zoom, configuration: configuration, appInstalled: { _ in true }),
                       .app(CalendarMeeting.appURL(for: zoom)!))
        XCTAssertEqual(CalendarMeeting.openTarget(for: zoom, configuration: configuration, appInstalled: { _ in false }),
                       .browser(zoom, bundleID: "com.google.Chrome"), "Without the Zoom app the chosen browser opens the link")
    }

    func testRecordingMatchesTheEventItOverlapsAndAsksWhenTwoFit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        let at = { (hour: Int, minute: Int) in
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: hour, minute: minute))!
        }
        let event = { (id: String, from: Date, to: Date) in CalendarMeeting(id: id, calendarID: "work", title: id, start: from, end: to) }
        let standup = event("standup", at(10, 0), at(10, 30))
        let sync = event("sync", at(10, 30), at(11, 0))
        let hour = event("hour", at(10, 0), at(11, 0))
        let short = event("short", at(10, 40), at(10, 50))
        var holiday = event("holiday", at(0, 0), at(23, 59)); holiday.allDay = true
        var declined = event("declined", at(9, 58), at(10, 31)); declined.declined = true

        XCTAssertEqual(CalendarMeeting.match(recordingStart: at(9, 58), recordingEnd: at(10, 31), events: [standup, holiday, declined]),
                       .linked(standup), "Joining early and leaving late still links")
        XCTAssertEqual(CalendarMeeting.match(recordingStart: at(10, 0), recordingEnd: at(11, 0), events: [sync, standup]),
                       .ambiguous([standup, sync]), "Two back-to-back meetings in one recording: ask")
        XCTAssertEqual(CalendarMeeting.match(recordingStart: at(10, 0), recordingEnd: at(10, 45), events: [hour, short]), .linked(hour))
        XCTAssertEqual(CalendarMeeting.match(recordingStart: at(12, 0), recordingEnd: at(12, 30), events: [standup, sync]), .none)
        XCTAssertEqual(CalendarMeeting.match(recordingStart: at(10, 0), recordingEnd: at(10, 0), events: [standup]), .none)
    }

    func testStopIsOfferedOnceAMinuteAfterTheLinkedMeetingEnds() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(id: "m", calendarID: "work", title: "Review", start: end.addingTimeInterval(-1800), end: end)
        let id = UUID()
        XCTAssertFalse(CalendarMeeting.stopPromptDue(meeting: meeting, recordingID: id, offered: [], now: end.addingTimeInterval(30)))
        XCTAssertTrue(CalendarMeeting.stopPromptDue(meeting: meeting, recordingID: id, offered: [], now: end.addingTimeInterval(60)))
        XCTAssertFalse(CalendarMeeting.stopPromptDue(meeting: meeting, recordingID: id, offered: [id], now: end.addingTimeInterval(600)))
        XCTAssertFalse(CalendarMeeting.stopPromptDue(meeting: nil, recordingID: id, offered: [], now: end.addingTimeInterval(600)),
                       "Recordings without a calendar event have no end to compare")
        XCTAssertFalse(CalendarMeeting.stopPromptDue(meeting: meeting, recordingID: nil, offered: [], now: end.addingTimeInterval(600)))
        XCTAssertFalse(CalendarMeeting.stopPromptDue(meeting: meeting, recordingID: id, offered: [], now: end.addingTimeInterval(600),
                                                     callActive: true),
                       "While the call goes on, the call detector offers Stop when it ends")
    }

    func testStartsInUsesTheRightUnitForTheDistance() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        let at = { (day: Int, hour: Int, minute: Int) in
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let now = at(23, 22, 30) // Friday evening
        let meeting = { (start: Date) in CalendarMeeting(id: "m", calendarID: "w", title: "M", start: start, end: start.addingTimeInterval(3600)) }
        let time = { (date: Date) in date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)) }
        XCTAssertEqual(meeting(at(23, 22, 42)).statusLine(now: now, calendar: calendar), String(localized: "Starts in \(12) min"))
        XCTAssertEqual(meeting(at(23, 23, 50)).statusLine(now: now, calendar: calendar), String(localized: "Starts in \(1) h \(20) min"))
        XCTAssertEqual(meeting(at(24, 9, 0)).statusLine(now: now, calendar: calendar), String(localized: "Tomorrow at \(time(at(24, 9, 0)))"))
        let monday = at(26, 9, 0)
        XCTAssertEqual(meeting(monday).statusLine(now: now, calendar: calendar),
                       String(localized: "\(monday.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide))) at \(time(monday))"))
        let later = at(31, 9, 0)
        XCTAssertEqual(meeting(later).statusLine(now: now, calendar: calendar),
                       String(localized: "\(later.formatted(Date.FormatStyle(timeZone: calendar.timeZone).day().month(.abbreviated))) at \(time(later))"))
    }

    func testJoinIsOfferedFromTenMinutesBeforeTheStartUntilTheEnd() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(id: "m", calendarID: "w", title: "M", start: start, end: start.addingTimeInterval(1800),
                                      meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertFalse(meeting.isJoinable(now: start.addingTimeInterval(-3 * 86400)), "Three days ahead there is nothing to join")
        XCTAssertFalse(meeting.isJoinable(now: start.addingTimeInterval(-601)))
        XCTAssertTrue(meeting.isJoinable(now: start.addingTimeInterval(-600)))
        XCTAssertTrue(meeting.isJoinable(now: start.addingTimeInterval(900)))
        XCTAssertFalse(meeting.isJoinable(now: start.addingTimeInterval(1800)))
    }
}
