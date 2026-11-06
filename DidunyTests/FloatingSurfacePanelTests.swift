import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// WP-20: the floating surface window, its keys, motion and key-focus rules (ADR-0012 D7, design-spec 5 M4 to M7).
@MainActor
struct FloatingSurfacePanelTests {
    // MARK: - Window configuration (search takes typing without activating Diduny)

    @Test("The surface is a borderless non-activating panel that can become key but never main")
    func panelTakesKeysWithoutActivating() {
        let panel = FloatingSurfacePanel()

        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(panel.isFloatingPanel)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.isSuperset(of: [.fullScreenAuxiliary, .transient, .ignoresCycle]))
        #expect(panel.backgroundColor == .clear)
        #expect(!panel.isOpaque)
        #expect(panel.hasShadow)
        #expect(!panel.isReleasedWhenClosed)
        // Above other floating windows such as the calendar reminder (ADR-0012 risks).
        #expect(panel.level == .popUpMenu)
    }

    // MARK: - Keys

    @Test("Arrow keys, Return, keypad Enter and Escape map to surface keys; others pass through", arguments: [
        (UInt16(126), FloatingSurfaceKey?.some(.up)),
        (125, .down),
        (36, .return),
        (76, .return),
        (53, .escape),
        (0, nil),
        (49, nil),
    ])
    func keyMapping(keyCode: UInt16, expected: FloatingSurfaceKey?) {
        #expect(FloatingSurfaceKey(keyCode: keyCode) == expected)
    }

    // MARK: - Motion (M4 to M7, Reduce Motion, keyboard opening)

    @Test("M4: menu opens in 180 ms ease-out from 95%")
    func menuOpen() {
        #expect(FloatingSurfaceMotion.open(.menu, reduceMotion: false, fromKeyboard: false)
            == .init(duration: 0.18, scale: 0.95, curve: .easeOut))
    }

    @Test("M6: popup opens in 200 ms ease-out from 95%")
    func popupOpen() {
        #expect(FloatingSurfaceMotion.open(.popup, reduceMotion: false, fromKeyboard: false)
            == .init(duration: 0.20, scale: 0.95, curve: .easeOut))
    }

    @Test("Reduce Motion: opening is a 120 ms opacity fade, no scale", arguments: [
        FloatingSurfaceMotion.Surface.menu, .popup,
    ])
    func reducedOpen(surface: FloatingSurfaceMotion.Surface) {
        #expect(FloatingSurfaceMotion.open(surface, reduceMotion: true, fromKeyboard: false)
            == .init(duration: 0.12, scale: 1, curve: .linear))
    }

    @Test("Opened from the keyboard: no entrance animation", arguments: [
        FloatingSurfaceMotion.Surface.menu, .popup,
    ])
    func keyboardOpen(surface: FloatingSurfaceMotion.Surface) {
        #expect(FloatingSurfaceMotion.open(surface, reduceMotion: false, fromKeyboard: true)
            == .init(duration: 0, scale: 1, curve: .instant))
    }

    @Test("M5: menu closes at once, with or without Reduce Motion", arguments: [false, true])
    func menuClose(reduceMotion: Bool) {
        #expect(FloatingSurfaceMotion.close(.menu, reduceMotion: reduceMotion)
            == .init(duration: 0, scale: 1, curve: .instant))
    }

    @Test("M7: popup closes in 150 ms ease-out to 95%; Reduce Motion fades in 120 ms")
    func popupClose() {
        #expect(FloatingSurfaceMotion.close(.popup, reduceMotion: false)
            == .init(duration: 0.15, scale: 0.95, curve: .easeOut))
        #expect(FloatingSurfaceMotion.close(.popup, reduceMotion: true)
            == .init(duration: 0.12, scale: 1, curve: .linear))
    }

    @Test("An instant step has no animation")
    func instantHasNoAnimation() {
        #expect(FloatingSurfaceMotion.animation(for: .init(duration: 0, scale: 1, curve: .instant)) == nil)
        #expect(FloatingSurfaceMotion.animation(for: .init(duration: 0.18, scale: 0.95, curve: .easeOut)) != nil)
    }

    // MARK: - Key focus after close (ADR-0012 D7 and risks)

    @Test("The parent gets key back only if it had it and the close happened inside Diduny", arguments: [
        (true, FloatingSurfaceCloseReason.picked, true),
        (true, .escape, true),
        (true, .trigger, true),
        (true, .clickInApp, true),
        (true, .programmatic, true),
        (true, .clickInOtherApp, false),
        (true, .resignedKey, false),
        (true, .replaced, false),
        (false, .picked, false),
        (false, .escape, false),
    ])
    func parentKeyRestore(parentWasKey: Bool, reason: FloatingSurfaceCloseReason, expected: Bool) {
        #expect(FloatingSurfacePresenter.restoresParentKey(parentWasKey: parentWasKey, reason: reason) == expected)
    }

    // MARK: - Command panel policies while a surface is open (ADR-0012 D7)

    @Test("The command panel does not collapse while a surface is open, wherever the pointer is")
    func hoverPolicyWithOpenSurface() {
        let panelFrame = NSRect(x: 1154, y: 287, width: 300, height: 326)
        let surfaceFrame = NSRect(x: 900, y: 100, width: 262, height: 260)
        let outside = NSPoint(x: 100, y: 100)

        #expect(!EdgeCommandPanelHoverPolicy.shouldCollapse(
            pointer: outside, panelFrame: panelFrame, isDragging: false, openSurfaceFrame: surfaceFrame
        ))
        #expect(!EdgeCommandPanelHoverPolicy.shouldCollapse(
            pointer: NSPoint(x: 950, y: 150), panelFrame: panelFrame, isDragging: false, openSurfaceFrame: surfaceFrame
        ))
        #expect(EdgeCommandPanelHoverPolicy.shouldCollapse(
            pointer: outside, panelFrame: panelFrame, isDragging: false, openSurfaceFrame: nil
        ))
    }

    @Test("The edge tab does not auto-hide while a surface is open")
    func autoHidePolicyWithOpenSurface() {
        let panelFrame = NSRect(x: 1400, y: 287, width: 40, height: 120)
        let outside = NSPoint(x: 100, y: 100)

        #expect(!EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: outside, panelFrame: panelFrame, isDragging: false, isExpanded: false,
            isShowingLiveFeedback: false, openSurfaceFrame: NSRect(x: 900, y: 100, width: 262, height: 260)
        ))
        #expect(EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: outside, panelFrame: panelFrame, isDragging: false, isExpanded: false,
            isShowingLiveFeedback: false, openSurfaceFrame: nil
        ))
    }
}

/// Opens a real surface over a non-activating parent and checks key focus and activation.
/// Drives real key windows, so it runs only on CI (`DIDUNY_UI_TESTS=1`), like `ShortcutsSettingsHitTestingTests`.
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DIDUNY_UI_TESTS"] == "1", "UI tests run on CI only")
)
struct FloatingSurfacePresenterWindowTests {
    private final class ParentPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private static func makeParent() -> NSPanel {
        let parent = ParentPanel(
            contentRect: NSRect(x: 400, y: 400, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        return parent
    }

    private static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    @Test("Opening a menu makes it key and a child of the parent without activating the app; Escape closes it")
    func menuTakesKeyWithoutActivation() {
        let presenter = FloatingSurfacePresenter()
        let parent = Self.makeParent()
        defer { presenter.close(); parent.orderOut(nil) }
        let wasActive = NSApp.isActive
        let model = PickerMenuModel.languages(
            (1...10).map { PickerMenuLanguage(code: "l\($0)", name: "Language \($0)") },
            yours: [],
            selectedCode: "l1"
        )

        presenter.toggleMenu(
            owner: "test.field", model: model, alignment: .leading,
            anchor: NSRect(x: 420, y: 560, width: 200, height: 30), parent: parent,
            fromKeyboard: true, onPick: { _ in }
        )
        Self.settle()

        let surface = parent.childWindows?.first
        #expect(surface is FloatingSurfacePanel)
        #expect(surface?.isKeyWindow == true)
        #expect(surface?.identifier?.rawValue == "pickerMenu")
        #expect(presenter.openOwnerID == "test.field")
        #expect(presenter.openSurfaceFrame != nil)
        #expect(NSApp.isActive == wasActive)

        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: surface?.windowNumber ?? 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )
        if let escape { surface?.sendEvent(escape) }
        Self.settle()

        #expect(presenter.openOwnerID == nil)
        #expect(parent.childWindows?.isEmpty ?? true)
        #expect(surface?.isVisible == false)
    }

    @Test("Toggling the same owner closes; opening another owner replaces the surface")
    func oneSurfaceAtATime() {
        let presenter = FloatingSurfacePresenter()
        let parent = Self.makeParent()
        defer { presenter.close(); parent.orderOut(nil) }
        let model = PickerMenuModel(
            groups: [PickerMenuGroup(id: "g", rows: [PickerMenuRow(id: "a", title: "A")])],
            selectedID: "a"
        )
        let anchor = NSRect(x: 420, y: 560, width: 200, height: 30)

        presenter.toggleMenu(owner: "one", model: model, alignment: .leading, anchor: anchor,
                             parent: parent, fromKeyboard: true, onPick: { _ in })
        presenter.toggleMenu(owner: "two", model: model, alignment: .trailing, anchor: anchor,
                             parent: parent, fromKeyboard: true, onPick: { _ in })
        Self.settle()
        #expect(presenter.openOwnerID == "two")
        #expect(parent.childWindows?.count == 1)

        presenter.toggleMenu(owner: "two", model: model, alignment: .trailing, anchor: anchor,
                             parent: parent, fromKeyboard: true, onPick: { _ in })
        Self.settle()
        #expect(presenter.openOwnerID == nil)
        #expect(parent.childWindows?.isEmpty ?? true)
    }
}
