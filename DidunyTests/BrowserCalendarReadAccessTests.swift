import XCTest
@testable import Diduny

final class ReadAccessTests: XCTestCase {
    func testRevocationStopsFurtherOperations() throws {
        let access = ReadAccess()
        try access.check()
        access.cancel()
        XCTAssertThrowsError(try access.check())
    }
    func testOneDeadlineCoversTheWholeReadIncludingDiscovery() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let access = ReadAccess(now: start)
        XCTAssertNoThrow(try access.check(now: start.addingTimeInterval(11)))
        XCTAssertThrowsError(try access.check(now: start.addingTimeInterval(12)))
    }
}
