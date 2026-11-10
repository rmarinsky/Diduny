import AppKit
@testable import Diduny
import Testing

/// After an Engine menu pick the pointer returns to the field: AppKit y up becomes CG y down.
struct PointerReturnTests {
    private let window = NSRect(x: 1000, y: 400, width: 300, height: 200)
    private let field = NSRect(x: 1010, y: 500, width: 100, height: 40)

    @Test("Inside the window the pointer stays")
    func insideStays() {
        #expect(PointerReturn.target(pointer: NSPoint(x: 1100, y: 450), windowFrame: window, field: field, primaryScreenMaxY: 1080) == nil)
    }

    @Test("Outside it goes to the field's centre, y flipped against the primary display")
    func outsideFlips() {
        let target = PointerReturn.target(pointer: NSPoint(x: 1100, y: 300), windowFrame: window, field: field, primaryScreenMaxY: 1080)
        #expect(target == CGPoint(x: 1060, y: 560))
    }

    @Test("A field on a display left of and above the primary keeps global coordinates")
    func otherDisplay() {
        let field = NSRect(x: -1500, y: 1200, width: 100, height: 40)
        let window = NSRect(x: -1510, y: 1100, width: 300, height: 200)
        let target = PointerReturn.target(pointer: NSPoint(x: -1400, y: 1000), windowFrame: window, field: field, primaryScreenMaxY: 1080)
        #expect(target == CGPoint(x: -1450, y: -140))
    }
}
