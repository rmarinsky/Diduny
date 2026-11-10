import AppKit
import SwiftUI

/// Opens and closes the one picker menu or popup on screen (ADR-0012 D7). App-wide: opening a surface closes the
/// current one. Never activates Diduny; the surface takes key as a non-activating child panel of the trigger's window.
@MainActor
@Observable
final class FloatingSurfacePresenter {
    static let shared = FloatingSurfacePresenter()

    /// The trigger whose surface is open; a picker field draws its "open" border from it.
    private(set) var openOwnerID: String?

    @ObservationIgnored private var current: OpenSurface?

    /// Frame of the open surface, for `EdgeCommandPanelHoverPolicy` and `EdgeCommandPanelAutoHidePolicy`.
    var openSurfaceFrame: NSRect? {
        current?.panel.frame
    }

    /// Posted after a surface closes (not when another one replaces it). `userInfo[closeReasonKey]` holds the
    /// `FloatingSurfaceCloseReason`. The command panel re-checks its collapse rule on it.
    static let didCloseNotification = Notification.Name("FloatingSurfacePresenter.didClose")
    static let closeReasonKey = "reason"

    init() {}

    /// Where key focus goes when a surface closes (ADR-0012 D7 and its risks section).
    enum KeyAfterClose: Equatable, Sendable {
        /// `parent.makeKey()`: Diduny is the active app (Settings) and the parent had key.
        case parentKey
        /// `parent.orderFront(nil)` only, never `makeKey`: the person's front app keeps the keyboard
        /// (the command panel over TextEdit). The ADR's fallback.
        case parentFront
        /// Leave key where it already went: another app, or the surface that replaced this one.
        case unchanged
    }

    static func keyAfterClose(
        parentWasKey: Bool,
        appIsActive: Bool,
        reason: FloatingSurfaceCloseReason
    ) -> KeyAfterClose {
        switch reason {
        case .clickInOtherApp, .resignedKey, .replaced: .unchanged
        case .picked, .escape, .trigger, .clickInApp, .programmatic:
            appIsActive && parentWasKey ? .parentKey : .parentFront
        }
    }

    func isOpen(owner: String) -> Bool {
        openOwnerID == owner
    }

    // MARK: - Open

    /// Opens the picker menu for `owner`, or closes it when it is already open (a click on the field toggles).
    /// - Parameter anchor: the trigger's frame in screen coordinates.
    func toggleMenu(
        owner: String,
        model: PickerMenuModel,
        alignment: FloatingSurfacePlacement.Alignment,
        anchor: NSRect,
        parent: NSWindow?,
        fromKeyboard: Bool,
        onPick: @escaping (String) -> Void
    ) {
        if isOpen(owner: owner) {
            close(.trigger)
            return
        }
        let state = PickerMenuState(model: model, onPick: onPick)
        let surface = open(
            owner: owner, identifier: PickerMenuModel.Identifier.menu, kind: .menu(alignment), motion: .menu,
            anchor: anchor, parent: parent, fromKeyboard: fromKeyboard, root: AnyView(PickerMenu(state: state))
        )
        state.close = { [weak self] reason in self?.close(reason) }
        state.onLayoutChange = { [weak self, weak surface] in
            guard let surface else { return }
            self?.refit(surface)
        }
        surface.panel.onKey = { [weak state] key in state?.handle(key) ?? false }
    }

    /// Opens a popup (`PopupShell` content) for `owner`, or closes it when it is already open.
    /// - Parameters:
    ///   - name: the identifier suffix, `popup.<name>` (test-plan 2.1), for example `languages.elevenlabs`.
    ///   - content: gets a `close` action for its close button.
    func togglePopup<Content: View>(
        owner: String,
        name: String,
        anchor: NSRect,
        parent: NSWindow?,
        fromKeyboard: Bool,
        @ViewBuilder content: (_ close: @escaping () -> Void) -> Content
    ) {
        if isOpen(owner: owner) {
            close(.trigger)
            return
        }
        let root = AnyView(content { [weak self] in self?.close(.programmatic) })
        let surface = open(
            owner: owner, identifier: PopupShellIdentifier.popup(name), kind: .popup, motion: .popup,
            anchor: anchor, parent: parent, fromKeyboard: fromKeyboard, root: root
        )
        surface.panel.onKey = { [weak self] key in
            guard key == .escape else { return false }
            self?.close(.escape)
            return true
        }
    }

    private func open(
        owner: String,
        identifier: String,
        kind: FloatingSurfacePlacement.Kind,
        motion: FloatingSurfaceMotion.Surface,
        anchor: NSRect,
        parent: NSWindow?,
        fromKeyboard: Bool,
        root: AnyView
    ) -> OpenSurface {
        close(.replaced)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = FloatingSurfaceTransition(
            open: FloatingSurfaceMotion.open(motion, reduceMotion: reduceMotion, fromKeyboard: fromKeyboard),
            close: FloatingSurfaceMotion.close(motion, reduceMotion: reduceMotion)
        )
        let panel = FloatingSurfacePanel()
        let hosting = FirstMouseSurfaceHostingView(rootView: FloatingSurfaceContainer(transition: transition, content: root))
        // The hosting view sits in a plain container with an autoresizing mask: its intrinsic size (and so
        // `fittingSize`) follows the content, but AppKit does not resize the window from the bottom-left on its
        // own. `refit` moves the window instead, keeping the edge at the trigger. (With `sizingOptions = []`
        // `fittingSize` is zero.)
        hosting.sizingOptions = [.intrinsicContentSize]
        let container = NSView(frame: NSRect(origin: .zero, size: hosting.fittingSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.setAccessibilityIdentifier(identifier)

        let visibleFrame = Self.visibleFrame(for: anchor, parent: parent)
        let placement = FloatingSurfacePlacement.frame(
            anchor: anchor, size: hosting.fittingSize, kind: kind, visibleFrame: visibleFrame
        )
        transition.scaleAnchor = placement.scaleAnchor
        transition.onShown = { [weak panel] in panel?.invalidateShadow() }
        panel.setFrame(placement.frame, display: false)

        let surface = OpenSurface(
            owner: owner, panel: panel, hosting: hosting, parent: parent, parentWasKey: parent?.isKeyWindow == true,
            kind: kind, anchor: anchor, side: placement.side, visibleFrame: visibleFrame, transition: transition
        )
        current = surface
        openOwnerID = owner

        parent?.addChildWindow(panel, ordered: .above)
        panel.level = .popUpMenu
        // Never `NSApp.activate`: the person keeps typing context in the app in front.
        panel.makeKeyAndOrderFront(nil)
        // Focus once the panel is key, not on appear: the search field takes typing at once.
        panel.focusFirstTextField()
        installCloseTriggers(for: surface)
        return surface
    }

    // MARK: - Close

    func close(_ reason: FloatingSurfaceCloseReason = .programmatic) {
        guard let surface = current else { return }
        current = nil
        openOwnerID = nil
        surface.removeCloseTriggers()

        let parent = surface.parent
        let panel = surface.panel
        // A popup fades out for 150 ms (M7): its search field takes no more keys meanwhile.
        panel.beginClosing()
        let remove = {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if reason == .replaced {
            remove()
        } else {
            surface.transition.hide(then: remove)
        }
        switch Self.keyAfterClose(parentWasKey: surface.parentWasKey, appIsActive: NSApp.isActive, reason: reason) {
        case .parentKey: parent?.makeKey()
        case .parentFront: parent?.orderFront(nil)
        case .unchanged: break
        }
        if reason != .replaced {
            NotificationCenter.default.post(
                name: Self.didCloseNotification, object: self, userInfo: [Self.closeReasonKey: reason]
            )
        }
    }

    // MARK: - Private

    /// The menu grows or shrinks while you type; keep its side and its edge at the trigger.
    private func refit(_ surface: OpenSurface) {
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface, current === surface else { return }
            let placement = FloatingSurfacePlacement.frame(
                anchor: surface.anchor, size: surface.hosting.fittingSize, kind: surface.kind,
                visibleFrame: surface.visibleFrame, keeping: surface.side
            )
            surface.panel.setFrame(placement.frame, display: true)
            surface.panel.invalidateShadow()
        }
    }

    private func installCloseTriggers(for surface: OpenSurface) {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        let global = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(.clickInOtherApp) }
        }
        // Clicks in Diduny's own windows. A click on the trigger closes and is swallowed, so the field does not
        // reopen on mouse-up (toggle).
        let local = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self, weak surface] event in
            guard let self, let surface, current === surface else { return event }
            if event.window === surface.panel { return event }
            if event.window === surface.parent, surface.anchor.contains(NSEvent.mouseLocation) {
                close(.trigger)
                return nil
            }
            close(.clickInApp)
            return event
        }
        surface.monitors = [global, local].compactMap { $0 }
        surface.resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: surface.panel, queue: .main
        ) { [weak self, weak surface] _ in
            MainActor.assumeIsolated {
                guard let self, let surface, self.current === surface else { return }
                self.close(.resignedKey)
            }
        }
    }

    private static func visibleFrame(for anchor: NSRect, parent: NSWindow?) -> NSRect {
        let centre = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? parent?.screen ?? NSScreen.main
        return screen?.visibleFrame ?? anchor.insetBy(dx: -1000, dy: -1000)
    }
}

// MARK: - Open surface

@MainActor
private final class OpenSurface {
    let owner: String
    let panel: FloatingSurfacePanel
    let hosting: NSView
    weak var parent: NSWindow?
    let parentWasKey: Bool
    let kind: FloatingSurfacePlacement.Kind
    let anchor: NSRect
    let side: FloatingSurfacePlacement.Side
    let visibleFrame: NSRect
    let transition: FloatingSurfaceTransition
    var monitors: [Any] = []
    var resignObserver: NSObjectProtocol?

    init(
        owner: String, panel: FloatingSurfacePanel, hosting: NSView, parent: NSWindow?, parentWasKey: Bool,
        kind: FloatingSurfacePlacement.Kind, anchor: NSRect, side: FloatingSurfacePlacement.Side,
        visibleFrame: NSRect, transition: FloatingSurfaceTransition
    ) {
        self.owner = owner
        self.panel = panel
        self.hosting = hosting
        self.parent = parent
        self.parentWasKey = parentWasKey
        self.kind = kind
        self.anchor = anchor
        self.side = side
        self.visibleFrame = visibleFrame
        self.transition = transition
    }

    func removeCloseTriggers() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

// MARK: - Open and close motion

/// Drives M4 to M7 on the surface content: scale from the trigger side plus opacity.
@MainActor
@Observable
final class FloatingSurfaceTransition {
    private(set) var isShown: Bool
    private(set) var hiddenScale: CGFloat
    var scaleAnchor: UnitPoint = .top
    /// The open animation finished (or there was none): the window shadow must follow the drawn shape.
    @ObservationIgnored var onShown: (() -> Void)?
    private let openStep: FloatingSurfaceMotion.Step
    private let closeStep: FloatingSurfaceMotion.Step

    init(open: FloatingSurfaceMotion.Step, close: FloatingSurfaceMotion.Step) {
        openStep = open
        closeStep = close
        hiddenScale = open.scale
        // No entrance animation: draw the first frame already shown.
        isShown = FloatingSurfaceMotion.animation(for: open) == nil
    }

    func show() {
        guard !isShown, let animation = FloatingSurfaceMotion.animation(for: openStep) else {
            isShown = true
            DispatchQueue.main.async { [weak self] in self?.onShown?() }
            return
        }
        withAnimation(animation) {
            isShown = true
        } completion: { [weak self] in
            self?.onShown?()
        }
    }

    func hide(then remove: @escaping () -> Void) {
        guard let animation = FloatingSurfaceMotion.animation(for: closeStep) else {
            remove()
            return
        }
        hiddenScale = closeStep.scale
        withAnimation(animation) { isShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + closeStep.duration, execute: remove)
    }
}

private struct FloatingSurfaceContainer: View {
    let transition: FloatingSurfaceTransition
    let content: AnyView

    var body: some View {
        content
            .focusRingOnlyAfterTab()
            .scaleEffect(transition.isShown ? 1 : transition.hiddenScale, anchor: transition.scaleAnchor)
            .opacity(transition.isShown ? 1 : 0)
            .onAppear { transition.show() }
    }
}

/// The first click on a row lands even if the surface is not key yet.
private final class FirstMouseSurfaceHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
