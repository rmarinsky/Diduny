@testable import Diduny
import XCTest

@MainActor final class CalendarConnectionTests: XCTestCase {
    func testConsentSelectionAndReminderHistoryRestoreButEventsRemainInMemory() async throws {
        let defaults = UserDefaults(suiteName: "CalendarConnectionTests-\(UUID())")!
        let snapshot = ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Account")], meetings: [])
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { snapshot })
        XCTAssertFalse(connection.configuration.connected)
        await connection.connect()
        XCTAssertTrue(connection.configuration.connected)
        XCTAssertEqual(connection.configuration.selected, ["work"])
        connection.selectCalendar("work", selected: false)
        let restored = CalendarConnection(defaults: defaults, authorize: { XCTFail("Must not ask on restore"); return false }, read: { snapshot })
        XCTAssertTrue(restored.configuration.connected)
        XCTAssertTrue(restored.configuration.selected.isEmpty)
        XCTAssertTrue(restored.meetings.isEmpty)
        restored.disconnect()
        let disconnected = CalendarConnection(defaults: defaults, authorize: { true }, read: { snapshot })
        XCTAssertFalse(disconnected.configuration.connected)
    }

    func testDisconnectRejectsLateReadAndDoesNotRestoreClearedConsent() async {
        let defaults = UserDefaults(suiteName: "CalendarLateReadTests-\(UUID())")!
        let gate = CalendarReadGate()
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { await gate.read() })
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
