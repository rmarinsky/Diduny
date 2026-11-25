import XCTest
@testable import Diduny

final class CalendarExtractionTests: XCTestCase {
    let google = URL(string: "https://calendar.google.com/calendar/u/0/r")!
    func testIdenticalRowsRemainDistinctWithoutProviderIdentifiers() throws {
        let row = PageNode(role: "AXButton", label: "Design review, 11:30 to 11:45, Friday, October 16, 2026, By A Person, Busy")
        let result = try CalendarExtraction.read(approved: true, pageURL: URL(string: "https://outlook.office.com/calendar/")!) { [row, row] }
        XCTAssertEqual(result.events.count, 2)
    }
    func testContentIsNeverReadBeforeConsentOrOnAnotherSite() {
        var accessed = false
        XCTAssertThrowsError(try CalendarExtraction.read(approved: false, pageURL: google) { accessed = true; return [] })
        XCTAssertThrowsError(try CalendarExtraction.read(approved: true, pageURL: URL(string:"https://outlook.office.com/mail/")!) { accessed = true; return [] })
        XCTAssertFalse(accessed)
    }
    func testGoogleLabelsPreserveTitleAndDisplayedTimeWithoutLocationOrAttendees() throws {
        let result = try CalendarExtraction.read(approved: true, pageURL: google) {
            [PageNode(role:"AXButton", label:"17:00 – 18:30, Planning, part 2, Персональне, Прийнято, Місце: Private address, 21 жовтня 2026"),
             PageNode(role:"AXButton", label:"Наступний період"),
             PageNode(role:"AXStaticText", label:"17:00 – 18:30, Not an event, 21 жовтня 2026")]
        }
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.title, "Planning, part 2")
        XCTAssertEqual(result.events.first?.displayedTime, "17:00 – 18:30")
        XCTAssertEqual(result.events.first?.displayedDate, "21 жовтня 2026")
    }
    func testOutlookLabelsAndOnlyActualSupportedJoinLinksAreExtracted() throws {
        let result = try CalendarExtraction.read(approved: true, pageURL: URL(string:"https://outlook.cloud.microsoft/calendar/view/workweek")!) {
            [PageNode(role:"AXButton", label:"Canceled: Design review, 11:30 to 11:45, Friday, October 16, 2026, By A Person, Free, Exception to recurring event"),
             PageNode(role:"AXLink",label:"Join",url:URL(string:"https://teams.microsoft.com/meet/123?p=secret")),
             PageNode(role:"AXLink",label:"Join",url:URL(string:"https://teams.microsoft.com/meet/123?p=secret")),
             PageNode(role:"AXLink",label:"Settings",url:URL(string:"https://teams.microsoft.com/meetingOptions/?token=secret")),
             PageNode(role:"AXLink",label:"Bad",url:URL(string:"https://meet.google.com.evil.test/abc-defg-hij")),
             PageNode(role:"AXStaticText",label:"https://meet.google.com/abc-defg-hij")]
        }
        XCTAssertEqual(result.provider, .microsoft)
        XCTAssertEqual(result.events.first?.title, "Canceled: Design review")
        XCTAssertEqual(result.events.first?.displayedDate,"Friday, October 16, 2026")
        XCTAssertEqual(result.events.first?.cancelled,true)
        XCTAssertEqual(result.meetingLinks.map(\.absoluteString),["https://teams.microsoft.com/meet/123?p=secret"])
    }

    func testBrowserRowsStayBesideAForwardedCopyAtTheSameTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let outlook = VisibleEvent(title: "Saqara Sync", displayedTime: "11:30 to 11:45", displayedDate: "Friday, October 16, 2026", cancelled: false)
        let forwarded = VisibleEvent(title: "Velocity Build Showcase", displayedTime: "1:30 PM to 2:00 PM", displayedDate: "Friday, October 16, 2026", cancelled: false)
        let google = VisibleEvent(title: "Planning, part 2", displayedTime: "17:00 – 18:30", displayedDate: "21 жовтня 2026", cancelled: false)
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let meetings = BrowserCalendarMeetings.make(events: [outlook, forwarded, google], windowName: "Diduny Calendar · test",
                                                    sourceTitle: "Outlook", from: day, to: next, calendar: calendar)
        XCTAssertEqual(meetings.map(\.title), ["Saqara Sync", "Velocity Build Showcase"])
        XCTAssertEqual(calendar.component(.hour, from: meetings[0].start), 11)
        XCTAssertEqual(calendar.component(.minute, from: meetings[0].end), 45)
        XCTAssertEqual(calendar.component(.hour, from: meetings[1].start), 13)
        let mac = CalendarMeeting(id: "mac", calendarID: "work", title: "FW: Velocity Build Showcase",
                                  start: meetings[1].start, end: meetings[1].end)
        let merged = CalendarMeetingMerge.merging([mac], with: meetings)
        XCTAssertEqual(merged.map(\.title), ["FW: Velocity Build Showcase", "Saqara Sync", "Velocity Build Showcase"])
        var memory = BrowserEventMemory()
        memory.replace(meetings, calendar: calendar)
        let tomorrow = BrowserCalendarMeetings.make(events: [google], windowName: "Diduny Calendar · test",
                                                    sourceTitle: "Outlook", from: .distantPast, to: .distantFuture, calendar: calendar)
        memory.replace(tomorrow, calendar: calendar)
        let kept = memory.overlapping(from: day, to: next)
        XCTAssertEqual(kept.map(\.title), ["Saqara Sync", "Velocity Build Showcase"])
        let before = memory.stored().map(\.title)
        memory.add([meetings[0]], calendar: calendar)
        XCTAssertEqual(memory.stored().map(\.title), before)
        let ukrainian = BrowserCalendarMeetings.range(dateText: google.displayedDate, timeText: google.displayedTime, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: ukrainian?.start ?? .distantPast), 21)
        XCTAssertEqual(calendar.component(.hour, from: ukrainian?.start ?? .distantPast), 17)
    }
}
