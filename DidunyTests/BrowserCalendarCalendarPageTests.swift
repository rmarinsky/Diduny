import XCTest
@testable import Diduny

final class CalendarPageTests: XCTestCase {
    func testOnlyHTTPSCalendarPagesMayBeRead() throws {
        XCTAssertEqual(CalendarPage.provider(for: URL(string: "https://calendar.google.com/calendar/u/0/r")!), .google)
        XCTAssertEqual(CalendarPage.provider(for: URL(string: "https://outlook.cloud.microsoft/calendar/view/workweek")!), .microsoft)
        XCTAssertEqual(CalendarPage.provider(for: URL(string: "https://outlook.office.com/calendar/item/demo")!), .microsoft)
        for text in ["http://calendar.google.com/calendar/", "https://calendar.google.com.evil.test/calendar/", "https://outlook.cloud.microsoft/mail/", "https://example.com/calendar/", "https://user:pass@calendar.google.com/calendar/", "https://calendar.google.com:444/calendar/"] {
            XCTAssertNil(CalendarPage.provider(for: URL(string: text)!), text)
        }
    }
}
