@testable import Diduny
import XCTest
import AppKit

@MainActor final class CalendarConnectionTests: XCTestCase {
    func testDueFullscreenReminderStaysAboveOtherAppsAndDismissesBeforeJoinWork() async {
        let defaults = UserDefaults(suiteName: "CalendarPanel-\(UUID())")!
        let event = CalendarMeeting(id: "synthetic", calendarID: "work", title: "Reminder test",
                                    start: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(600),
                                    meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let snapshot = ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: [event])
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in snapshot })
        let controller = CalendarReminderController()
        defer { controller.dismiss(); connection.disconnect() }
        connection.updatePreferences { $0.fullScreen = true; $0.reminderMinutes = 0 }
        connection.onReminder = { controller.show($0, connection: connection) }
        await connection.connect()
        guard let panel = controller.window else { return XCTFail("Due event must present its reminder") }
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.hidesOnDeactivate, "Reminder must remain visible while another app is active")
        XCTAssertEqual(panel.level, .screenSaver, "Fullscreen reminder must cover other app windows")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        var joined = false
        connection.onJoin = { _, record, _ in
            XCTAssertFalse(panel.isVisible, "Hide the banner before browser or recording work starts")
            XCTAssertNil(controller.window)
            XCTAssertFalse(record)
            joined = true
        }
        controller.join(event, record: false, connection: connection)
        XCTAssertTrue(joined)
        await connection.refresh()
        XCTAssertNil(controller.window, "Refreshing must not redisplay the joined occurrence")
    }

    func testConsentSelectionAndReminderHistoryRestoreButEventsRemainInMemory() async throws {
        let defaults = UserDefaults(suiteName: "CalendarConnectionTests-\(UUID())")!
        let snapshot = ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Account")], meetings: [])
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in snapshot })
        XCTAssertFalse(connection.configuration.connected)
        await connection.connect()
        XCTAssertTrue(connection.configuration.connected)
        XCTAssertEqual(connection.configuration.selected, ["work"])
        connection.selectCalendar("work", selected: false)
        let restored = CalendarConnection(defaults: defaults, authorize: { XCTFail("Must not ask on restore"); return false }, read: { _ in snapshot })
        XCTAssertTrue(restored.configuration.connected)
        XCTAssertTrue(restored.configuration.selected.isEmpty)
        XCTAssertTrue(restored.meetings.isEmpty)
        restored.disconnect()
        let disconnected = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in snapshot })
        XCTAssertFalse(disconnected.configuration.connected)
    }

    func testCalendarSourceLabelsExplainGenericNamesWithoutGuessingProviders() {
        XCTAssertEqual(CalendarChoice(id: "1", title: "Calendar", source: "Default", sourceKind: .local).displaySource,
                       String(localized: "On this Mac"))
        XCTAssertEqual(CalendarChoice(id: "2", title: "Calendar", source: "Other", sourceKind: .birthdays).displaySource,
                       String(localized: "Birthdays"))
        XCTAssertEqual(CalendarChoice(id: "3", title: "Calendar", source: "Work", sourceKind: .exchange).displaySource, "Work")
        XCTAssertEqual(CalendarChoice(id: "4", title: "Calendar", source: "Default", sourceKind: .calDAV).displaySource,
                       String(localized: "CalDAV account"))
    }

    func testEditableExchangeServiceCalendarsAreNotSuggestedByName() {
        for title in ["Дні народження", "Свята (Україна)", "Свята в Україні", "Birthdays", "Holidays", "  BIRTHDAYS  "] {
            XCTAssertFalse(CalendarChoice(id: title, title: title, source: "Exchange").suggested, title)
        }
        for title in ["Work", "Персональне", "Birthday campaign planning"] {
            XCTAssertTrue(CalendarChoice(id: title, title: title, source: "Exchange").suggested, title)
        }
    }

    func testInitialSelectionExcludesOtherCalendarsAndPreservesManualOptInAfterRestore() async {
        let defaults = UserDefaults(suiteName: "CalendarDefaults-\(UUID())")!
        let snapshot = ScheduledCalendarSnapshot(calendars: [
            .init(id: "work", title: "Work", source: "Account"),
            .init(id: "birthdays", title: "Birthdays", source: "Other", eligibleForSuggestion: false),
            .init(id: "subscription", title: "Shared schedule", source: "Account", eligibleForSuggestion: false)
        ], meetings: [])
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in snapshot })
        await connection.connect()
        XCTAssertEqual(connection.configuration.selected, ["work"])
        connection.selectCalendar("birthdays", selected: true)
        let restored = CalendarConnection(defaults: defaults, authorize: { XCTFail("No new consent"); return false }, read: { _ in snapshot })
        await restored.refresh()
        XCTAssertEqual(restored.configuration.selected, ["work", "birthdays"])
    }

    func testNoLinkEventCanRecordAndDeselectedEventsCannotActOrRemainInMemory() async {
        let defaults = UserDefaults(suiteName: "CalendarSelection-\(UUID())")!
        let event = CalendarMeeting(id: "local", calendarID: "work", title: "In person", start: Date(), end: Date().addingTimeInterval(600))
        let snapshot = ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Account")], meetings: [event])
        var scopes: [Set<String>?] = []
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { selected in scopes.append(selected); return snapshot })
        await connection.connect()
        var actions = 0
        connection.onJoin = { received, record, local in
            XCTAssertEqual(received, event); XCTAssertTrue(record); XCTAssertTrue(local); actions += 1
        }
        connection.join(event, record: false)
        XCTAssertEqual(actions, 0)
        connection.join(event, record: true)
        XCTAssertEqual(actions, 1)
        connection.selectCalendar("work", selected: false)
        XCTAssertTrue(connection.meetings.isEmpty)
        await connection.refresh()
        XCTAssertTrue(connection.meetings.isEmpty)
        connection.join(event, record: true)
        XCTAssertEqual(actions, 1)
        XCTAssertNil(scopes.first!)
        XCTAssertEqual(scopes.last!, Set<String>())
        connection.disconnect()
    }

    func testDisconnectRejectsLateReadAndDoesNotRestoreClearedConsent() async {
        let defaults = UserDefaults(suiteName: "CalendarLateReadTests-\(UUID())")!
        let gate = CalendarReadGate()
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in await gate.read() })
        let task = Task { await connection.connect() }
        while !(await gate.waiting) { await Task.yield() }
        connection.disconnect()
        await gate.finish()
        await task.value
        XCTAssertFalse(connection.configuration.connected)
        XCTAssertTrue(connection.meetings.isEmpty)
        XCTAssertNil(connection.fetchedAt)
    }
}

private actor CalendarReadGate {
    var continuation: CheckedContinuation<ScheduledCalendarSnapshot, Never>?
    var waiting: Bool { continuation != nil }
    func read() async -> ScheduledCalendarSnapshot {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: ScheduledCalendarSnapshot(calendars: [], meetings: [
            CalendarMeeting(id: "late", calendarID: "work", title: "Late", start: Date(), end: Date().addingTimeInterval(600))
        ]))
        continuation = nil
    }
}
