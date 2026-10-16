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
}
