import AppKit
import ApplicationServices

/// Placement of the in-place translation badge/toast and AX lookup of the selection bounds.
enum InplaceTranslationAnchor {
    struct ScreenInfo: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    static let gap: CGFloat = 6
    static let cursorOffset: CGFloat = 12
    static let edgeInset: CGFloat = 8

    /// Converts an AX rect (top-left origin, relative to the primary screen) to AppKit coordinates.
    static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Frame (AppKit coordinates) for a panel of `size`.
    /// - `selectionEnd`: rect of the last selected line in AppKit coordinates, if known.
    /// - Falls back to the mouse position when the rect is missing, empty, or off every screen.
    static func panelFrame(
        size: CGSize,
        selectionEnd: CGRect?,
        mouse: CGPoint,
        screens: [ScreenInfo]
    ) -> CGRect {
        let fallbackScreen = screens.first { $0.frame.contains(mouse) } ?? screens.first

        if let rect = selectionEnd, !rect.isEmpty,
           let screen = screens.first(where: { $0.frame.contains(CGPoint(x: rect.maxX, y: rect.midY)) })
           ?? screens.first(where: { $0.frame.intersects(rect) })
        {
            let bounds = screen.visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
            let y = rect.midY - size.height / 2
            var x = rect.maxX + gap
            if x + size.width > bounds.maxX {
                x = rect.minX - gap - size.width
            }
            return clamped(CGRect(origin: CGPoint(x: x, y: y), size: size), to: bounds)
        }

        let bounds = (fallbackScreen?.visibleFrame ?? CGRect(origin: .zero, size: size))
            .insetBy(dx: edgeInset, dy: edgeInset)
        let origin = CGPoint(x: mouse.x + cursorOffset, y: mouse.y - cursorOffset - size.height)
        return clamped(CGRect(origin: origin, size: size), to: bounds)
    }

    private static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var result = rect
        result.origin.x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
        result.origin.y = max(bounds.minY, min(rect.minY, bounds.maxY - rect.height))
        return result
    }

    // MARK: - AX lookup

    /// Rect (AppKit coordinates) of the last selected character in the focused element, or nil.
    /// Blocking; call off the main thread. Never reads or logs the text itself.
    static func selectionEndRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement // swiftlint:disable:this force_cast

        var rangeRef: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID(),
              AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), // swiftlint:disable:this force_cast
              range.length > 0
        else { return nil }

        var last = CFRange(location: range.location + range.length - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &last) else { return nil }

        var boundsRef: CFTypeRef?
        var rect = CGRect.zero
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &boundsRef
        ) == .success,
            let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID(),
            AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), // swiftlint:disable:this force_cast
            !rect.isEmpty
        else { return nil }

        guard let primary = NSScreen.screens.first else { return nil }
        return appKitRect(fromAX: rect, primaryScreenHeight: primary.frame.height)
    }
}
