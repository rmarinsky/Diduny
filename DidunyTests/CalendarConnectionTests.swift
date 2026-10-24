@testable import Diduny
import XCTest
import AppKit
import SwiftUI

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

    func testMenuSelectionRefreshesUnavailableSnapshotAndOpensTheSelectedOccurrence() async {
        let defaults = UserDefaults(suiteName: "CalendarMenu-\(UUID())")!
        let event = CalendarMeeting(id: "menu", calendarID: "work", title: "Review",
                                    start: Date(), end: Date().addingTimeInterval(600),
                                    meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let snapshot = ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: [event])
        var failRead = false
        var reads = 0
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in
            reads += 1
            if failRead { throw URLError(.notConnectedToInternet) }
            return snapshot
        })
        defer { connection.disconnect() }
        await connection.connect()
        // The native menu retains its selected row while a background refresh fails.
        failRead = true
        await connection.refresh()
        XCTAssertNil(connection.fetchedAt)
        failRead = false
        var opened: [URL] = []
        connection.onJoin = { meeting, record, _ in
            XCTAssertFalse(record, "Opening a link must preserve the recording opt-out")
            if let url = meeting.meetingURL { opened.append(url) }
        }
        await connection.joinFromMenu(event, record: false)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(opened, [event.meetingURL!])
    }

    func testMenuSelectionReportsRefreshFailureAndChangedMeetingWithoutOpeningOldLink() async {
        let defaults = UserDefaults(suiteName: "CalendarMenuFailure-\(UUID())")!
        let event = CalendarMeeting(id: "menu", calendarID: "work", title: "Review",
                                    start: Date(), end: Date().addingTimeInterval(600),
                                    meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        var latest = event
        var failRead = false
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in
            if failRead { throw URLError(.notConnectedToInternet) }
            return ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: [latest])
        })
        defer { connection.disconnect() }
        await connection.connect()
        connection.onJoin = { _, _, _ in XCTFail("Never open a stale or changed link") }
        failRead = true
        await connection.refresh()
        let unavailable = await connection.joinFromMenu(event, record: false)
        XCTAssertEqual(unavailable, String(localized: "Calendar access could not be refreshed. Open Calendar settings and try again."))
        failRead = false
        latest.meetingURL = URL(string: "https://meet.google.com/xyz-abcd-efg")
        let changed = await connection.joinFromMenu(event, record: false)
        XCTAssertEqual(changed, String(localized: "This meeting changed or is no longer available. Reopen the Diduny menu and select it again."))
    }

    func testNativeUpcomingMenuDispatchesSelectedURLThroughAppDelegateWithoutRecording() async throws {
        let defaults = UserDefaults(suiteName: "CalendarNativeMenu-\(UUID())")!
        let event = CalendarMeeting(id: "menu", calendarID: "work", title: "Synthetic menu meeting",
                                    start: Date(), end: Date().addingTimeInterval(600),
                                    meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let ended = CalendarMeeting(id: "ended", calendarID: "work", title: "Synthetic ended meeting",
                                    start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(-1))
        var failRead = false
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in
            if failRead { throw URLError(.notConnectedToInternet) }
            return ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: [event, ended])
        })
        defer { connection.disconnect() }
        await connection.connect()
        let delegate = AppDelegate()
        let opened = expectation(description: "Selected meeting reaches the system URL opening boundary")
        connection.onJoin = { meeting, record, local in
            XCTAssertFalse(record)
            delegate.joinCalendarMeeting(meeting, record: record, local: local, openURL: { url in
                XCTAssertEqual(url, event.meetingURL)
                opened.fulfill()
                return true
            })
        }
        let menu = NSMenu()
        Self.builder(connection).items().forEach(menu.addItem)
        XCTAssertNotNil(menu.items.first?.view as? NSHostingView<CalendarTimelineView>, "The live day timeline leads the menu")
        XCTAssertNotNil(menu.items.dropFirst().first?.view, "The next-meeting card follows the timeline")
        XCTAssertTrue(menu.items.contains { $0.title.hasPrefix(String(localized: "Today")) })
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix(String(localized: "Tomorrow")) })
        XCTAssertFalse(zip(menu.items, menu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })
        XCTAssertFalse(menu.items.contains { $0.title == String(localized: "Typing Speed Test…") }, "Typing test lives in the window")
        let endedRow = try XCTUnwrap(menu.items.first { $0.title.contains(ended.title) })
        XCTAssertFalse(endedRow.isEnabled, "Ended meetings stay visible but cannot be joined")
        XCTAssertNil(endedRow.submenu)
        let actions = try XCTUnwrap(menu.items.first { $0.title.contains(event.title) }?.submenu)
        XCTAssertTrue(actions.items.contains { $0.title == String(localized: "Join and record") })
        let index = try XCTUnwrap(actions.items.firstIndex { $0.title == String(localized: "Join") })
        XCTAssertTrue(actions.items[index].isEnabled)
        failRead = true
        await connection.refresh()
        failRead = false
        actions.performActionForItem(at: index)
        await fulfillment(of: [opened], timeout: 3)

        connection.updatePreferences { $0.hideNames = true }
        let hidden = Self.builder(connection).calendarItems()
        XCTAssertFalse(hidden.contains { $0.title.contains(event.title) }, "Hidden names never reach the menu")
        XCTAssertTrue(hidden.contains { $0.title.contains(String(localized: "Meeting")) })
    }

    private static func builder(_ connection: CalendarConnection) -> StatusMenuBuilder {
        StatusMenuBuilder(appState: AppState(), audioDeviceManager: AudioDeviceManager(), connection: connection, actions: .init(
            toggleRecording: {}, toggleTranslation: {}, toggleMeeting: {}, toggleMeetingTranslation: {},
            batchFilesAndURLs: {}, openMainWindow: { _ in }))
    }

    /// Writes the menu timeline in light and dark so reviewers can see it without a local build.
    func testMenuTimelineScreenshots() throws {
        let now = Date()
        let hour = Calendar.current.dateInterval(of: .hour, for: now)!.start
        let event = { (id: String, from: Double, to: Double) in
            CalendarMeeting(id: id, calendarID: "work", title: id,
                            start: hour.addingTimeInterval(from * 3600), end: hour.addingTimeInterval(to * 3600))
        }
        let timeline = CalendarTimeline(meetings: [event("past", -1.5, -1.25), event("current", 0, 1),
                                                   event("a", 3, 3.5), event("b", 3.5, 4), event("c", 4, 4.5)], now: now)
        let outputDirectory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let image = try XCTUnwrap(CalendarTimelineView.image(timeline, appearance: NSAppearance(named: appearance)))
            let attachment = XCTAttachment(image: image)
            attachment.name = "Menu timeline - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let outputDirectory, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: outputDirectory.appendingPathComponent("menu-timeline-\(name).png"))
            }
        }
    }

    /// Design references for the meetings work: the real reminder windows, Meetings settings
    /// and the menu bar menu structure, written to SCREENSHOT_DIR on CI.
    func testMeetingsDesignReferenceScreenshots() async throws {
        let outputDirectory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        let now = Date()
        let hour = Calendar.current.dateInterval(of: .hour, for: now)!.start
        let event = { (id: String, title: String, from: Double, to: Double, link: String?) in
            CalendarMeeting(id: id, calendarID: "work", title: title,
                            start: hour.addingTimeInterval(from * 3600), end: hour.addingTimeInterval(to * 3600),
                            meetingURL: link.flatMap(URL.init(string:)))
        }
        var review = event("review", "Design review: meetings menu", 0, 1, "https://meet.google.com/abc-defg-hij")
        review.calendarTitle = "Work"
        review.calendarColorRGB = 0x4285F4
        review.location = "Room 4 · Kyiv office"
        review.notes = "1. Meeting-now screen: what it shows and when\n2. Menu and settings simplification\n3. Linking recordings to calendar events"
        review.attendees = [
            CalendarAttendee(name: "Roman Marinsky", email: "roman@example.com", response: .accepted, isOrganizer: true, isCurrentUser: true),
            CalendarAttendee(name: "Olena Kovalenko", email: "olena@example.com", response: .accepted),
            CalendarAttendee(name: "Taras Bondar", email: "taras@example.com", response: .tentative),
            CalendarAttendee(name: nil, email: "qa-team@example.com", response: .pending),
        ]
        let meetings = [
            event("tennis", "Tennis", -3, -2, nil),
            event("sync", "Team velocity sync", -1, -0.75, "https://teams.microsoft.com/l/meetup-join/19%3ameeting"),
            review,
            event("ba", "Neovolta: BA AI Automation", 3, 3.5, "https://meet.google.com/abc-defg-hij"),
            event("qa", "Neovolta: QA AI Automation", 4, 4.5, "https://zoom.us/j/123456789"),
        ]
        let defaults = UserDefaults(suiteName: "CalendarDesignReference-\(UUID())")!
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in
            ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Google", sourceKind: .calDAV, colorRGB: 0x4285F4),
                                                  .init(id: "home", title: "Personal", source: "iCloud", sourceKind: .iCloud, colorRGB: 0x34A853)],
                                      meetings: meetings)
        })
        defer { connection.disconnect() }
        await connection.connect()

        func write(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let outputDirectory, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
            }
        }

        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            // Rendered without presenting a window: a screen-saver-level panel would take key
            // focus from UI tests that click into their own windows while this runs.
            for (name, size) in [("popup", CGSize(width: 560, height: 620)), ("fullscreen", CGSize(width: 1280, height: 800))] {
                let reminder = NSHostingView(rootView: CalendarReminderView(
                    meetings: [meetings[2], meetings[3]], connection: connection, fullScreen: name == "fullscreen",
                    dismiss: {}, close: {}, snooze: { _ in }, join: { _, _ in }))
                reminder.appearance = NSAppearance(named: appearance)
                reminder.frame = CGRect(origin: .zero, size: size)
                try write(reminder, "reference-reminder-\(name)-\(appearanceName)")
            }
            let settings = NSHostingView(rootView: Form { CalendarSettingsSection(connection: connection) }
                .formStyle(.grouped).frame(width: 640, height: 820))
            settings.appearance = NSAppearance(named: appearance)
            settings.frame = CGRect(x: 0, y: 0, width: 640, height: 820)
            try write(settings, "reference-meetings-settings-\(appearanceName)")
            let audio = NSHostingView(rootView: MeetingAudioSettingsView().frame(width: 640, height: 900))
            audio.appearance = NSAppearance(named: appearance)
            audio.frame = CGRect(x: 0, y: 0, width: 640, height: 900)
            try write(audio, "reference-meeting-audio-settings-\(appearanceName)")
        }

        let menu = NSMenu()
        Self.builder(connection).items().forEach(menu.addItem)
        func dump(_ menu: NSMenu, _ depth: Int) -> [String] {
            menu.items.flatMap { item -> [String] in
                let title = item.view.map { "[\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height))]" } ?? item.title
                let line = String(repeating: "  ", count: depth) + (item.isSeparatorItem ? "---" :
                    title + (item.isEnabled ? "" : " (disabled)")
                    + (item.keyEquivalent.isEmpty ? "" : " ⌘\(item.keyEquivalent)"))
                return [line] + (item.submenu.map { dump($0, depth + 1) } ?? [])
            }
        }
        if let outputDirectory {
            try dump(menu, 0).joined(separator: "\n").write(to: outputDirectory.appendingPathComponent("reference-menu-structure.txt"),
                                                             atomically: true, encoding: .utf8)
        }
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for (index, name) in [(0, "timeline"), (1, "next-meeting-card")] {
                let view = try XCTUnwrap(menu.items[index].view)
                view.appearance = NSAppearance(named: appearance)
                try write(view, "reference-menu-\(name)-\(appearanceName)")
            }
        }
    }

    func testDismissedOrDetectedMeetingIsNotOfferedAgainAfterWake() async {
        let defaults = UserDefaults(suiteName: "CalendarAcknowledge-\(UUID())")!
        let event = CalendarMeeting(id: "running", calendarID: "work", title: "Running",
                                    start: Date().addingTimeInterval(-900), end: Date().addingTimeInterval(900),
                                    meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let other = CalendarMeeting(id: "other", calendarID: "work", title: "Other",
                                    start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(1800))
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in
            ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: [event, other])
        })
        defer { connection.disconnect() }
        var shown: [[String]] = []
        connection.onReminder = { shown.append($0.map(\.id)) }
        await connection.connect()
        XCTAssertEqual(shown, [["running", "other"]], "Running meetings are offered by default")

        connection.acknowledge([event]) // Dismiss on the meeting-now screen
        connection.acknowledgeMeetingsInProgress() // The call detector saw a call
        connection.resetReminderSession()
        XCTAssertEqual(shown.count, 1, "Dismissed and detected meetings are not offered again after wake")

        connection.setScreenLocked(true)
        connection.setScreenLocked(false)
        XCTAssertEqual(shown.count, 1)
    }

    func testAgendasAndPeopleAreOnByDefaultAndCanBeTurnedOff() async throws {
        let defaults = UserDefaults(suiteName: "CalendarEventDetails-\(UUID())")!
        let saved = #"{"version":1,"connected":true,"selected":["work"],"ledger":{}}"#
        defaults.set(Data(saved.utf8), forKey: "calendar.connection.v1")
        var event = CalendarMeeting(id: "e", calendarID: "work", title: "Review", start: Date(), end: Date().addingTimeInterval(600))
        event.notes = "Agenda"
        event.location = "Room 4"
        event.attendees = [CalendarAttendee(name: "Olena", email: "olena@example.com", response: .accepted)]
        let connection = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in
            ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: [event])
        }, readRange: { _, _, _ in [event] })
        defer { connection.disconnect() }
        XCTAssertTrue(connection.configuration.eventDetails, "Calendars connected earlier get agendas and people too")
        await connection.refresh()
        XCTAssertEqual(connection.meetings.first?.attendees, event.attendees)
        XCTAssertEqual(connection.meetings.first?.notes, "Agenda")

        await connection.setEventDetails(false)
        let stripped = try XCTUnwrap(connection.meetings.first)
        XCTAssertNil(stripped.notes)
        XCTAssertNil(stripped.location)
        XCTAssertNil(stripped.attendees)
        let read = try await connection.readMeetings(from: Date().addingTimeInterval(-60), to: Date())
        XCTAssertNil(read.first?.attendees)

        let restored = CalendarConnection(defaults: defaults, authorize: { true }, read: { _ in
            ScheduledCalendarSnapshot(calendars: [], meetings: [])
        })
        XCTAssertFalse(restored.configuration.eventDetails, "Turning it off is remembered")
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
