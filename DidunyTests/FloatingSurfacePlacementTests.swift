import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// WP-20: where a picker menu or popup opens (ADR-0012 D7, design-spec 4.2 and 4.9).
/// AppKit screen coordinates: y grows upwards, so "below the trigger" is a smaller y.
struct FloatingSurfacePlacementTests {
    /// A 1440 x 900 screen without the 25 pt menu bar.
    private static let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private static let menu = NSSize(width: 262, height: 260)
    private static let tallMenu = NSSize(width: 262, height: 320)
    private static let popup = NSSize(width: 460, height: 364)

    /// The frame stays 16 pt inside the visible frame on every side.
    private static func isInset(_ frame: NSRect, in visible: NSRect = screen) -> Bool {
        frame.minX >= visible.minX + 16 - 0.001
            && frame.maxX <= visible.maxX - 16 + 0.001
            && frame.minY >= visible.minY + 16 - 0.001
            && frame.maxY <= visible.maxY - 16 + 0.001
    }

    // MARK: - Menu

    @Test("Menu: 4 below the trigger, left edges aligned")
    func menuBelowLeading() {
        let anchor = NSRect(x: 500, y: 600, width: 274, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.menu, kind: .menu(.leading), visibleFrame: Self.screen
        )

        #expect(result.frame == NSRect(x: 500, y: 336, width: 262, height: 260))
        #expect(result.side == .below)
        #expect(result.scaleAnchor == .topLeading)
    }

    @Test("Right-aligned menu: right edges aligned, grows from the top-right corner")
    func menuBelowTrailing() {
        let anchor = NSRect(x: 500, y: 600, width: 274, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.menu, kind: .menu(.trailing), visibleFrame: Self.screen
        )

        #expect(result.frame.maxX == anchor.maxX)
        #expect(result.frame.maxY == anchor.minY - 4)
        #expect(result.scaleAnchor == .topTrailing)
    }

    // MARK: - Dock edges (the command panel is 300 wide; fields sit 13 in from its edges)

    @Test("Panel docked right: a left-aligned menu from the right field of a pair is pulled in to 16 from the edge")
    func dockRightClampsX() {
        let anchor = NSRect(x: 1300, y: 600, width: 127, height: 42)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.menu, kind: .menu(.leading), visibleFrame: Self.screen
        )

        #expect(result.frame.maxX == 1424) // 1440 - 16
        #expect(result.side == .below)
        #expect(Self.isInset(result.frame))
    }

    @Test("Panel docked left: the menu keeps 16 from the left edge")
    func dockLeftClampsX() {
        let anchor = NSRect(x: 13, y: 600, width: 274, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.menu, kind: .menu(.leading), visibleFrame: Self.screen
        )

        #expect(result.frame.minX == 16)
        #expect(Self.isInset(result.frame))
    }

    @Test("Panel docked top: the menu opens below")
    func dockTopOpensBelow() {
        let anchor = NSRect(x: 570, y: 800, width: 274, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.tallMenu, kind: .menu(.leading), visibleFrame: Self.screen
        )

        #expect(result.side == .below)
        #expect(result.frame.maxY == 796)
        #expect(Self.isInset(result.frame))
    }

    @Test("Panel docked bottom: no room below, so the menu flips above and grows from its bottom corner")
    func dockBottomFlipsAbove() {
        let anchor = NSRect(x: 570, y: 120, width: 274, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.tallMenu, kind: .menu(.leading), visibleFrame: Self.screen
        )

        #expect(result.side == .above)
        #expect(result.frame.minY == anchor.maxY + 4)
        #expect(result.scaleAnchor == .bottomLeading)
        #expect(Self.isInset(result.frame))
    }

    @Test("A right-aligned menu that flips above grows from its bottom-right corner")
    func trailingAboveAnchor() {
        let anchor = NSRect(x: 570, y: 120, width: 274, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.tallMenu, kind: .menu(.trailing), visibleFrame: Self.screen
        )

        #expect(result.scaleAnchor == .bottomTrailing)
    }

    @Test("Below must leave 16 from the bottom edge, or the menu flips")
    func belowNeedsTheInset() {
        // 10 pt short of fitting below with the 16 pt inset.
        let anchor = NSRect(x: 570, y: 16 + 4 + 260 - 10, width: 274, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.menu, kind: .menu(.leading), visibleFrame: Self.screen
        )

        #expect(result.side == .above)
    }

    // MARK: - Popup

    @Test("Popup: centred on the trigger, 8 below, grows from the trigger centre")
    func popupCentredBelow() {
        let anchor = NSRect(x: 500, y: 500, width: 100, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.popup, kind: .popup, visibleFrame: Self.screen
        )

        #expect(result.frame == NSRect(x: 320, y: 128, width: 460, height: 364))
        #expect(result.side == .below)
        #expect(result.scaleAnchor == UnitPoint(x: 0.5, y: 0))
    }

    @Test("Popup at the top-left corner: clamped 16 from the left; scale origin follows the trigger")
    func popupTopLeftCorner() {
        let anchor = NSRect(x: 0, y: 845, width: 100, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.popup, kind: .popup, visibleFrame: Self.screen
        )

        #expect(result.frame.minX == 16)
        #expect(result.side == .below)
        #expect(result.frame.maxY == 837) // 845 - 8
        #expect(abs(result.scaleAnchor.x - (50 - 16) / 460) < 0.0001)
        #expect(result.scaleAnchor.y == 0)
        #expect(Self.isInset(result.frame))
    }

    @Test("Popup at the bottom-right corner: clamped right, flipped above, origin at the trigger's near edge")
    func popupBottomRightCorner() {
        let anchor = NSRect(x: 1340, y: 0, width: 100, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.popup, kind: .popup, visibleFrame: Self.screen
        )

        #expect(result.frame.maxX == 1424) // 1440 - 16
        #expect(result.side == .above)
        #expect(result.frame.minY == 38) // 30 + 8
        #expect(result.scaleAnchor.y == 1)
        #expect(abs(result.scaleAnchor.x - (1390 - 964) / 460) < 0.0001)
        #expect(Self.isInset(result.frame))
    }

    @Test("Popup at the top-right and bottom-left corners stays inside the screen")
    func popupOtherCorners() {
        let topRight = FloatingSurfacePlacement.frame(
            anchor: NSRect(x: 1340, y: 845, width: 100, height: 30),
            size: Self.popup, kind: .popup, visibleFrame: Self.screen
        )
        let bottomLeft = FloatingSurfacePlacement.frame(
            anchor: NSRect(x: 0, y: 0, width: 100, height: 30),
            size: Self.popup, kind: .popup, visibleFrame: Self.screen
        )

        #expect(topRight.side == .below)
        #expect(Self.isInset(topRight.frame))
        #expect(bottomLeft.side == .above)
        #expect(Self.isInset(bottomLeft.frame))
    }

    @Test("The scale origin stays on the surface when the trigger is past its edge")
    func scaleAnchorIsClamped() {
        let anchor = NSRect(x: 1430, y: 500, width: 10, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.popup, kind: .popup, visibleFrame: Self.screen
        )

        #expect(result.scaleAnchor.x == 1)
    }

    // MARK: - Neither side fits, kept side, other screens

    @Test("When neither side fits, the roomier side wins and the frame is clamped inside")
    func neitherSideFits() {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 400)
        let anchor = NSRect(x: 100, y: 180, width: 200, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.tallMenu, kind: .menu(.leading), visibleFrame: visible
        )

        #expect(result.side == .above)
        #expect(result.frame.maxY == 384) // 400 - 16
        #expect(Self.isInset(result.frame, in: visible))
    }

    @Test("A kept side does not flip while the menu shrinks or grows")
    func keptSide() {
        let anchor = NSRect(x: 570, y: 120, width: 274, height: 30)
        let small = NSSize(width: 262, height: 62)
        let free = FloatingSurfacePlacement.frame(
            anchor: anchor, size: small, kind: .menu(.leading), visibleFrame: Self.screen
        )
        let kept = FloatingSurfacePlacement.frame(
            anchor: anchor, size: small, kind: .menu(.leading), visibleFrame: Self.screen, keeping: .above
        )

        #expect(free.side == .below)
        #expect(kept.side == .above)
        #expect(kept.frame.minY == anchor.maxY + 4)
    }

    @Test("A second screen with its own origin uses its own edges")
    func secondScreen() {
        let visible = NSRect(x: 1440, y: -200, width: 1920, height: 1055)
        let anchor = NSRect(x: 3340, y: 400, width: 20, height: 30)
        let result = FloatingSurfacePlacement.frame(
            anchor: anchor, size: Self.menu, kind: .menu(.leading), visibleFrame: visible
        )

        #expect(result.frame.maxX == visible.maxX - 16)
        #expect(Self.isInset(result.frame, in: visible))
    }
}
