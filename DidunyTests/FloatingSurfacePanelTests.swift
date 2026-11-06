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

    @Test("Where key goes after a close", arguments: [
        // Settings: Diduny is active and the parent had key, so the parent takes key back.
        (true, true, FloatingSurfaceCloseReason.picked, FloatingSurfacePresenter.KeyAfterClose.parentKey),
        (true, true, .escape, .parentKey),
        (true, true, .trigger, .parentKey),
        (true, true, .clickInApp, .parentKey),
        (true, true, .programmatic, .parentKey),
        // Command panel over TextEdit: Diduny is not active. Never makeKey; only order the parent front,
        // so TextEdit keeps typing and the paste.
        (true, false, .picked, .parentFront),
        (false, false, .escape, .parentFront),
        (false, true, .picked, .parentFront),
        // Key already went elsewhere: leave it there.
        (true, true, .clickInOtherApp, .unchanged),
        (true, true, .resignedKey, .unchanged),
        (true, false, .resignedKey, .unchanged),
        (true, true, .replaced, .unchanged),
    ])
    func keyAfterClose(parentWasKey: Bool, appIsActive: Bool, reason: FloatingSurfaceCloseReason, expected: FloatingSurfacePresenter.KeyAfterClose) {
        #expect(FloatingSurfacePresenter.keyAfterClose(
            parentWasKey: parentWasKey, appIsActive: appIsActive, reason: reason
        ) == expected)
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

    @Test("After a surface closes with the pointer outside, the expanded panel collapses")
    func collapseAfterSurfaceClose() {
        let panelFrame = NSRect(x: 1154, y: 287, width: 300, height: 326)
        let outside = NSPoint(x: 100, y: 100)
        let inside = NSPoint(x: 1200, y: 400)

        #expect(EdgeCommandPanelHoverPolicy.shouldCollapseAfterSurfaceClose(
            pointer: outside, panelFrame: panelFrame, isExpanded: true, isDragging: false
        ))
        #expect(!EdgeCommandPanelHoverPolicy.shouldCollapseAfterSurfaceClose(
            pointer: inside, panelFrame: panelFrame, isExpanded: true, isDragging: false
        ))
        #expect(!EdgeCommandPanelHoverPolicy.shouldCollapseAfterSurfaceClose(
            pointer: outside, panelFrame: panelFrame, isExpanded: false, isDragging: false
        ))
        #expect(!EdgeCommandPanelHoverPolicy.shouldCollapseAfterSurfaceClose(
            pointer: outside, panelFrame: panelFrame, isExpanded: true, isDragging: true
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

/// Opens a real surface over a non-activating parent and checks key focus, activation and closing.
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

    /// Records app activations and surface closes while a test runs.
    private final class Observers {
        var activations = 0
        var closeReasons: [FloatingSurfaceCloseReason] = []
        private var tokens: [NSObjectProtocol] = []

        init() {
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.activations += 1 })
            tokens.append(NotificationCenter.default.addObserver(
                forName: FloatingSurfacePresenter.didCloseNotification, object: nil, queue: nil
            ) { [weak self] note in
                if let reason = note.userInfo?[FloatingSurfacePresenter.closeReasonKey] as? FloatingSurfaceCloseReason {
                    self?.closeReasons.append(reason)
                }
            })
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }

    private static let anchor = NSRect(x: 420, y: 560, width: 200, height: 30)

    private static func makeParent() -> NSPanel {
        // Drop events left from a previous test so the next dequeue is ours.
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
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

    /// Spins the run loop until `condition` holds or the deadline passes; returns whether it held.
    @discardableResult
    private static func spin(until condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func languages() -> PickerMenuModel {
        PickerMenuModel.languages(
            (1...10).map { PickerMenuLanguage(code: "l\($0)", name: "Language \($0)") },
            yours: [],
            selectedCode: "l1"
        )
    }

    private static func open(_ presenter: FloatingSurfacePresenter, owner: String = "test.field", parent: NSWindow) {
        presenter.toggleMenu(
            owner: owner, model: languages(), alignment: .leading, anchor: anchor, parent: parent,
            fromKeyboard: true, onPick: { _ in }
        )
    }

    private static func sendEscape(to window: NSWindow) {
        guard let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ) else { return }
        window.sendEvent(escape)
    }

    @Test("A menu takes key as a popUpMenu child of the parent, focuses search, and never activates the app")
    func menuTakesKeyWithoutActivation() {
        let presenter = FloatingSurfacePresenter()
        let parent = Self.makeParent()
        let observers = Observers()
        defer { presenter.close(); parent.orderOut(nil) }

        Self.open(presenter, parent: parent)
        let surface = parent.childWindows?.first
        Self.spin { surface?.isKeyWindow == true }

        #expect(surface is FloatingSurfacePanel)
        #expect(surface?.isKeyWindow == true)
        #expect(surface?.level == .popUpMenu)
        #expect(surface?.identifier?.rawValue == "pickerMenu")
        #expect(presenter.openOwnerID == "test.field")
        #expect(presenter.openSurfaceFrame != nil)
        // The search field's editor has the caret.
        let editor = surface?.firstResponder as? NSTextView
        #expect(editor?.delegate is NSTextField)
        #expect(observers.activations == 0)
    }

    @Test("Escape closes the menu; key then goes where keyAfterClose says")
    func escapeClosesAndKeyGoesBack() {
        let presenter = FloatingSurfacePresenter()
        let parent = Self.makeParent()
        let observers = Observers()
        defer { presenter.close(); parent.orderOut(nil) }
        parent.makeKey()
        Self.spin { parent.isKeyWindow }
        let parentWasKey = parent.isKeyWindow

        Self.open(presenter, parent: parent)
        let surface = parent.childWindows?.first
        Self.spin { surface?.isKeyWindow == true }
        if let surface { Self.sendEscape(to: surface) }
        Self.spin { surface?.isVisible == false }

        #expect(presenter.openOwnerID == nil)
        #expect(parent.childWindows?.isEmpty ?? true)
        #expect(surface?.isVisible == false)
        #expect(observers.closeReasons == [.escape])
        let expected = FloatingSurfacePresenter.keyAfterClose(
            parentWasKey: parentWasKey, appIsActive: NSApp.isActive, reason: .escape
        )
        Self.spin { parent.isKeyWindow == (expected == .parentKey) }
        #expect(parent.isKeyWindow == (expected == .parentKey))
        #expect(parent.isVisible)
        #expect(observers.activations == 0)
    }

    @Test("A mouse-down in the parent outside the trigger closes the menu")
    func outsideClickCloses() {
        let presenter = FloatingSurfacePresenter()
        let parent = Self.makeParent()
        let observers = Observers()
        defer { presenter.close(); parent.orderOut(nil) }

        Self.open(presenter, parent: parent)
        Self.spin { parent.childWindows?.first?.isKeyWindow == true }
        // Bottom-left of the parent, far from the trigger.
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: parent.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else {
            Issue.record("no mouse event")
            return
        }
        // Through the queue so the local monitor sees it.
        NSApp.postEvent(down, atStart: false)
        if let queued = NSApp.nextEvent(matching: .leftMouseDown, until: Date().addingTimeInterval(1),
                                        inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        Self.spin { presenter.openOwnerID == nil }

        #expect(presenter.openOwnerID == nil)
        #expect(observers.closeReasons == [.clickInApp])
    }

    @Test("Toggling the same owner closes; opening another owner replaces the surface")
    func oneSurfaceAtATime() {
        let presenter = FloatingSurfacePresenter()
        let parent = Self.makeParent()
        defer { presenter.close(); parent.orderOut(nil) }

        Self.open(presenter, owner: "one", parent: parent)
        Self.open(presenter, owner: "two", parent: parent)
        Self.spin { parent.childWindows?.first?.isKeyWindow == true }
        #expect(presenter.openOwnerID == "two")
        #expect(parent.childWindows?.count == 1)

        Self.open(presenter, owner: "two", parent: parent)
        Self.spin { parent.childWindows?.isEmpty ?? true }
        #expect(presenter.openOwnerID == nil)
        #expect(parent.childWindows?.isEmpty ?? true)
    }
}
