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
    func testOnlyOneExactCalendarAndProfileMayResume() {
        let saved = SavedConnection(browserID: "com.google.Chrome", profileName: "Work", calendarURL: url)
        XCTAssertEqual(saved.matchingCandidate(urls: [url, url], profiles: ["Personal", "Work"], windowTitles: [saved.windowName, saved.windowName]), 1)
        XCTAssertNil(saved.matchingCandidate(urls: [url, url], profiles: ["Work", "Work"], windowTitles: [saved.windowName, saved.windowName]))
        XCTAssertNil(saved.matchingCandidate(urls: [url], profiles: [nil], windowTitles: [saved.windowName]))
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
        XCTAssertThrowsError(try SavedConnection(browserID: "com.google.Chrome", profileName: "Work", calendarURL: URL(string: "https://calendar.google.com/calendar/u/0/r?eid=private")!).validate())
    }
}
