import XCTest
@testable import Diduny

final class SyncSessionTests: XCTestCase {
    func testOneConsentAllowsRepeatedReadsOnlyForConnectedSource() {
        var session = SyncSession()
        XCTAssertNil(session.begin(source: "window-a", now: 0))
        session.connect(source: "window-a")
        let first = session.begin(source: "window-a", now: 0)
        XCTAssertNotNil(first)
        XCTAssertNil(session.begin(source: "window-a", now: 61), "Do not overlap reads")
        XCTAssertTrue(session.finish(first!, now: 1))
        XCTAssertNil(session.begin(source: "window-b", now: 61), "No consent for another window")
        XCTAssertNil(session.begin(source: "window-a", now: 59))
        XCTAssertNotNil(session.begin(source: "window-a", now: 61))
    }
    func testDisconnectRejectsLateResultsAndReconnectDoesNotReuseOldRead() {
        var session = SyncSession()
        session.connect(source: "window-a")
        let old = session.begin(source: "window-a", now: 0)!
        session.disconnect()
        XCTAssertFalse(session.finish(old, now: 1))
        XCTAssertNil(session.begin(source: "window-a", now: 100))
        session.connect(source: "window-a")
        XCTAssertFalse(session.finish(old, now: 101))
        XCTAssertNotNil(session.begin(source: "window-a", now: 101))
    }
}
