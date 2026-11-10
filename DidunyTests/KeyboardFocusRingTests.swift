import AppKit
@testable import Diduny
import Testing

/// The focus ring shows only after Tab; Tab keeps working on panels (Roman's DEV feedback).
@MainActor
struct KeyboardFocusRingTests {
    private func event(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    @Test("Hidden until Tab; other keys do not show it")
    func tabShowsTheRing() {
        let ring = KeyboardFocusRing()
        #expect(!ring.isVisible)
        ring.note(keyCode: 49)
        #expect(!ring.isVisible)
        ring.note(keyCode: 48)
        #expect(ring.isVisible)
    }

    @Test("A mouse click or reopening hides it again")
    func mouseHidesTheRing() throws {
        let ring = KeyboardFocusRing()
        ring.note(keyCode: 48)
        ring.note(try #require(event(.leftMouseDown)))
        #expect(!ring.isVisible)
        ring.note(keyCode: 48)
        ring.hide()
        #expect(!ring.isVisible)
    }
}
