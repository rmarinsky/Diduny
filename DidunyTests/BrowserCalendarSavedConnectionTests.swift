import XCTest
@testable import Diduny
final class SavedConnectionTests: XCTestCase {
    let url = URL(string: "https://calendar.google.com/calendar/u/0/r")!
    func testConnectionAndConsentSurviveNewStoreInstanceAndDisconnectRemovesThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = SavedConnection(browserID: "com.google.Chrome", profileName: "Work", calendarURL: url)
        let store = ConnectionStore(directory: dir)
        XCTAssertNil(try store.load())
        try store.save(saved)
        XCTAssertEqual(try ConnectionStore(directory: dir).load(), saved)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: store.file)
        XCTAssertFalse(text.contains("meetingLinks"))
        try store.clear()
        XCTAssertNil(try ConnectionStore(directory: dir).load())
    }
    func testLastReadMeetingsSurviveANewStoreAndDisconnectRemovesThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConnectionStore(directory: dir)
        let meeting = CalendarMeeting(id: "browser:window:1:Saqara", calendarID: "browser:window", title: "Saqara",
                                      start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try store.loadMeetings(), [])
        try store.saveMeetings([meeting])
        XCTAssertEqual(try ConnectionStore(directory: dir).loadMeetings(), [meeting])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.meetingsFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.meetingsFile.path))
        XCTAssertEqual(try store.loadMeetings(), [])
    }
    func testOnlyOneExactCalendarAndProfileMayResume() {
        let saved = SavedConnection(browserID: "com.google.Chrome", profileName: "Work", calendarURL: url)
        XCTAssertEqual(saved.matchingCandidate(urls: [url, url], profiles: ["Personal", "Work"], windowTitles: [saved.windowName, saved.windowName]), 1)
        XCTAssertNil(saved.matchingCandidate(urls: [url, url], profiles: ["Work", "Work"], windowTitles: [saved.windowName, saved.windowName]))
        XCTAssertEqual(saved.matchingCandidate(urls: [url], profiles: [nil], windowTitles: [saved.windowName]), 0, "A named window with an unreadable profile control is still that window")
        XCTAssertNil(saved.matchingCandidate(urls: [url, url], profiles: [nil, nil], windowTitles: [saved.windowName, saved.windowName]))
        XCTAssertNil(saved.matchingCandidate(urls: [URL(string: "https://calendar.google.com/calendar/u/1/r")!], profiles: ["Work"], windowTitles: [saved.windowName]))
    }
    func testInvalidOrNewConsentVersionCannotRestore() throws {
        var saved = SavedConnection(browserID: "com.google.Chrome", profileName: "Work", calendarURL: url)
        saved.version = 2
        XCTAssertThrowsError(try saved.validate())
        XCTAssertThrowsError(try SavedConnection(browserID: "", profileName: "", calendarURL: URL(string: "https://example.com")!).validate())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConnectionStore(directory: dir)
        try Data("bad".utf8).write(to: store.file)
        XCTAssertThrowsError(try store.load())
    }
    func testAReusedProfileNameCannotRestoreAnUnmarkedWindow() {
        let saved = SavedConnection(browserID: "com.google.Chrome", profileName: "Work", calendarURL: url)
        XCTAssertNil(saved.matchingCandidate(urls: [url], profiles: ["Work"], windowTitles: ["Calendar - Google Chrome – Work"]))
        XCTAssertEqual(saved.matchingCandidate(urls: [url], profiles: ["Work"], windowTitles: [saved.windowName + " - Google Chrome – Work"]), 0)
        XCTAssertNil(saved.matchingCandidate(urls: [url], profiles: ["Work"], windowTitles: ["Other " + saved.windowName]))
        let week = URL(string: "https://outlook.cloud.microsoft/calendar/view/week")!
        let outlook = SavedConnection(browserID: "com.microsoft.edgemac", profileName: "Work", calendarURL: week)
        let workweek = URL(string: "https://outlook.cloud.microsoft/calendar/view/workweek/")!
        let item = URL(string: "https://outlook.cloud.microsoft/calendar/item/abc")!
        XCTAssertTrue(SavedConnection.sameCalendar(week, workweek))
        XCTAssertTrue(SavedConnection.sameCalendar(week, item))
        XCTAssertEqual(outlook.matchingCandidate(urls: [workweek], profiles: ["Work"], windowTitles: [outlook.windowName]), 0)
        let named = SavedConnection(browserID: "com.microsoft.edgemac", profileName: "Work", calendarURL: week, windowName: "Diduny Calendar · 9C870DC8-31DA-4DE6-98EB-D5E674F8F8B6")
        let shortened = "Diduny Calendar · 9C870D…A-4DE6-98EB-D5E674F8F8B6"
        XCTAssertTrue(SavedConnection.matchesWindowTitle(shortened, name: named.windowName))
        XCTAssertEqual(named.matchingCandidate(urls: [week], profiles: [nil], windowTitles: [shortened]), 0)
        XCTAssertNil(named.matchingCandidate(urls: [week], profiles: ["Personal"], windowTitles: [shortened]))
        XCTAssertFalse(SavedConnection.sameCalendar(week, URL(string: "https://outlook.cloud.microsoft/mail/")!))
        XCTAssertFalse(SavedConnection.sameCalendar(week, URL(string: "https://outlook.office.com/calendar/view/week")!))
        XCTAssertTrue(SavedConnection.sameCalendar(url, URL(string: "https://calendar.google.com/calendar/u/0/r/week")!))
        XCTAssertThrowsError(try SavedConnection(browserID: "com.google.Chrome", profileName: "Work", calendarURL: URL(string: "https://calendar.google.com/calendar/u/0/r?eid=private")!).validate())
    }
}
