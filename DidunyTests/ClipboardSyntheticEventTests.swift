import CoreGraphics
@testable import Diduny
import XCTest

final class ClipboardSyntheticEventTests: XCTestCase {
    func testShortcutEventsCarryTheDidunyMarker() throws {
        let events = try XCTUnwrap(ClipboardService.makeShortcutEvents(keyCode: 9, flags: .maskCommand))

        for event in [events.keyDown, events.keyUp] {
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), ClipboardService.syntheticEventMarker)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 9)
            XCTAssertTrue(event.flags.contains(.maskCommand))
        }
        XCTAssertEqual(events.keyDown.type, .keyDown)
        XCTAssertEqual(events.keyUp.type, .keyUp)
    }

    func testMarkerSpellsDidunyAndDiffersFromPapugas() {
        XCTAssertEqual(ClipboardService.syntheticEventMarker, 0x4449_4455_4E59)
        XCTAssertNotEqual(ClipboardService.syntheticEventMarker, 0x5041_5055_4741)
    }
}
