import AppKit
import SwiftUI

/// The window behind every picker menu and popup (ADR-0012 D7). A borderless child panel that takes the
/// keyboard without activating Diduny, so search works while another app stays frontmost.
final class FloatingSurfacePanel: NSPanel {
    /// Arrow keys, Return and Escape go here first, before the search field's editor eats them.
    /// Return true when the key was handled.
    var onKey: ((FloatingSurfaceKey) -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        // A menu sits above every floating window, the calendar reminder and the parent panel included.
        level = .popUpMenu
    }

    /// Set when the surface starts to close: it takes no more keys while it fades out.
    private(set) var isClosing = false

    override var canBecomeKey: Bool { !isClosing }
    override var canBecomeMain: Bool { false }

    func beginClosing() {
        isClosing = true
        onKey = nil
        ignoresMouseEvents = true
        makeFirstResponder(nil)
    }

    /// Puts the caret in the first editable text field (the search field), if there is one. Call after the
    /// panel became key.
    func focusFirstTextField() {
        contentView?.layoutSubtreeIfNeeded()
        if let field = contentView.flatMap(Self.firstEditableTextField) {
            makeFirstResponder(field)
        }
    }

    private static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstEditableTextField(in: subview) { return field }
        }
        return nil
    }

    override func sendEvent(_ event: NSEvent) {
        if isClosing, event.type == .keyDown || event.type == .keyUp { return }
        if event.type == .keyDown,
           !isComposingText,
           let key = FloatingSurfaceKey(keyCode: event.keyCode),
           onKey?(key) == true
        {
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onKey?(.escape) != true { super.cancelOperation(sender) }
    }

    /// An input method is composing (marked text): Return and arrows belong to it.
    private var isComposingText: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() == true
    }
}

/// The keys a floating surface handles itself.
enum FloatingSurfaceKey: Equatable, Sendable {
    case up, down, `return`, escape

    init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .return
        case 53: self = .escape
        default: return nil
        }
    }
}

/// Why a surface closed; decides whether the parent window gets key back.
enum FloatingSurfaceCloseReason: Equatable, Sendable {
    case picked, escape
    /// Click on the trigger that opened it (toggle).
    case trigger
    /// Mouse-down in another Diduny window or elsewhere in the parent.
    case clickInApp
    case clickInOtherApp
    case resignedKey
    /// Another surface opened.
    case replaced
    case programmatic
}

// MARK: - Placement

/// Pure frame math in AppKit screen coordinates (y up). ADR-0012 D7: a menu sits 4 below the trigger, left or
/// right aligned; a popup is centred and 8 below. Both flip above when needed and keep 16 from the screen edges.
enum FloatingSurfacePlacement {
    enum Alignment: Equatable, Sendable { case leading, trailing }

    enum Kind: Equatable, Sendable {
        case menu(Alignment)
        case popup
    }

    enum Side: Equatable, Sendable { case below, above }

    struct Result: Equatable {
        let frame: NSRect
        let side: Side
        /// SwiftUI unit point (y down) the open and close scale grows from (M4, M6, M7).
        let scaleAnchor: UnitPoint
    }

    static let menuGap: CGFloat = 4
    static let popupGap: CGFloat = 8
    static let screenInset: CGFloat = 16

    /// - Parameter keeping: the side chosen when the surface opened; pass it on a refit so a menu that
    ///   shrinks while you type does not jump to the other side.
    static func frame(
        anchor: NSRect,
        size: NSSize,
        kind: Kind,
        visibleFrame: NSRect,
        keeping: Side? = nil
    ) -> Result {
        let gap = kind == .popup ? popupGap : menuGap
        let inner = visibleFrame.insetBy(dx: screenInset, dy: screenInset)

        let side = keeping ?? chooseSide(anchor: anchor, height: size.height, gap: gap, inner: inner)
        var y = side == .below ? anchor.minY - gap - size.height : anchor.maxY + gap
        // Clamp, keeping the top inset when the surface is taller than the screen.
        y = min(max(y, inner.minY), inner.maxY - size.height)

        var x: CGFloat = switch kind {
        case .menu(.leading): anchor.minX
        case .menu(.trailing): anchor.maxX - size.width
        case .popup: anchor.midX - size.width / 2
        }
        x = max(min(x, inner.maxX - size.width), inner.minX)

        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        return Result(frame: frame, side: side, scaleAnchor: scaleAnchor(kind: kind, side: side, anchor: anchor, frame: frame))
    }

    private static func chooseSide(anchor: NSRect, height: CGFloat, gap: CGFloat, inner: NSRect) -> Side {
        let roomBelow = anchor.minY - gap - inner.minY
        let roomAbove = inner.maxY - (anchor.maxY + gap)
        if roomBelow >= height { return .below }
        if roomAbove >= height { return .above }
        return roomAbove > roomBelow ? .above : .below
    }

    private static func scaleAnchor(kind: Kind, side: Side, anchor: NSRect, frame: NSRect) -> UnitPoint {
        switch (kind, side) {
        case (.menu(.leading), .below): return .topLeading
        case (.menu(.trailing), .below): return .topTrailing
        case (.menu(.leading), .above): return .bottomLeading
        case (.menu(.trailing), .above): return .bottomTrailing
        case (.popup, _):
            // The trigger's centre on the near edge (P:459).
            let x = frame.width > 0 ? (anchor.midX - frame.minX) / frame.width : 0.5
            return UnitPoint(x: min(max(x, 0), 1), y: side == .below ? 0 : 1)
        }
    }
}

// MARK: - Motion

/// M4 to M7 (design-spec 5) as plain values, so the choice under Reduce Motion and keyboard opening is testable.
enum FloatingSurfaceMotion {
    enum Surface: Equatable, Sendable { case menu, popup }

    struct Step: Equatable {
        let duration: Double
        /// Scale at the hidden end: where opening starts and closing ends.
        let scale: CGFloat
        let curve: DS.Motion.Curve
    }

    private static let none = Step(duration: 0, scale: 1, curve: .instant)
    private static let fade = Step(duration: 0.12, scale: 1, curve: .linear)

    static func open(_ surface: Surface, reduceMotion: Bool, fromKeyboard: Bool) -> Step {
        // Anything opened from the keyboard appears without its entrance animation (design-spec 5).
        if fromKeyboard { return none }
        let token = surface == .menu ? DS.Motion.m4MenuOpen : DS.Motion.m6PopupOpen
        return step(token, reduceMotion: reduceMotion)
    }

    static func close(_ surface: Surface, reduceMotion: Bool) -> Step {
        step(surface == .menu ? DS.Motion.m5MenuClose : DS.Motion.m7PopupClose, reduceMotion: reduceMotion)
    }

    static func animation(for step: Step) -> Animation? {
        switch step.curve {
        case .easeOut: DS.Motion.easeOut(step.duration)
        case .easeInOut: DS.Motion.easeInOut(step.duration)
        // `fade` is `DS.Motion.reduced`: linear 120 ms.
        case .linear: .linear(duration: step.duration)
        case .instant, .native: nil
        }
    }

    private static func step(_ token: DS.Motion.Token, reduceMotion: Bool) -> Step {
        if token.curve == .instant { return none }
        if reduceMotion {
            switch token.reducedMotion {
            case .opacityFade: return fade
            case .instant, .skip: return none
            case .same, .native: break
            }
        }
        return Step(duration: token.duration, scale: DS.Motion.popScale, curve: token.curve)
    }
}
