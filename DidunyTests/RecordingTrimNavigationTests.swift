@testable import Diduny
import XCTest

@MainActor
final class RecordingTrimNavigationTests: XCTestCase {
    func testNavigationAllowedWithoutEditor() {
        let navigation = RecordingTrimNavigation()
        XCTAssertFalse(navigation.isEditing)
        XCTAssertTrue(navigation.requestLeave())
    }

    func testKeepEditingBlocksNavigationAndRetainsGuard() {
        let navigation = RecordingTrimNavigation()
        navigation.canLeave = { false }
        XCTAssertTrue(navigation.isEditing)
        XCTAssertFalse(navigation.requestLeave())
        XCTAssertTrue(navigation.isEditing)
    }

    func testGuardRunsOnEachRequestAndCanClearAfterSaveOrDiscard() {
        let navigation = RecordingTrimNavigation()
        var requests = 0
        navigation.canLeave = { requests += 1; return requests > 1 }
        XCTAssertFalse(navigation.requestLeave())
        XCTAssertTrue(navigation.requestLeave())
        XCTAssertEqual(requests, 2)
        navigation.canLeave = nil
        XCTAssertFalse(navigation.isEditing)
        XCTAssertTrue(navigation.requestLeave())
    }
}
