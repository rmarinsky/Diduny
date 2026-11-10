import AppKit
import ApplicationServices

/// The focused element's caret through AX: the character before the insertion point
/// (the end of a selection when there is one). Never reads the text itself. Chromium and
/// Electron get their tree turned on first (`ChromiumAccessibility`), and when they answer
/// only with text markers, the marker range's bounds are used.
struct AXCaretGeometry: CaretGeometry {
    func caret() -> CaretPosition? {
        ChromiumAccessibility.prepareFrontmost()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement // swiftlint:disable:this force_cast

        if let range = selectedRange(element), let position = characterBefore(range, in: element) {
            return position
        }
        return markerCaret(element, location: selectedRange(element).map { $0.location + $0.length })
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID(),
              AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) // swiftlint:disable:this force_cast
        else { return nil }
        return range
    }

    private func characterBefore(_ range: CFRange, in element: AXUIElement) -> CaretPosition? {
        let end = range.location + range.length
        guard end > 0 else { return nil }
        var before = CFRange(location: end - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &before) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &boundsRef
        ) == .success, let rect = Self.rect(boundsRef) else { return nil }
        return CaretPosition(location: end, rect: rect)
    }

    /// Chromium: `AXSelectedTextMarkerRange` + `AXBoundsForTextMarkerRange`. A collapsed caret has
    /// zero width, so it gets 1 pt. Without an integer location the poll after the paste cannot see
    /// the caret move, and the logo stays where it is.
    private func markerCaret(_ element: AXUIElement, location: Int?) -> CaretPosition? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange
        else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsRef
        ) == .success, let rect = Self.rect(boundsRef, widenCollapsed: true) else { return nil }
        return CaretPosition(location: location ?? 0, rect: rect)
    }

    private static func rect(_ ref: CFTypeRef?, widenCollapsed: Bool = false) -> CGRect? {
        var rect = CGRect.zero
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID(),
              AXValueGetValue(ref as! AXValue, .cgRect, &rect), // swiftlint:disable:this force_cast
              let primary = NSScreen.screens.first
        else { return nil }
        if widenCollapsed, rect.width == 0, rect.height > 0 {
            rect = CGRect(x: rect.minX - 1, y: rect.minY, width: 1, height: rect.height)
        }
        return PasteMarkPlan.plausibleCaretRect(
            InplaceTranslationAnchor.appKitRect(fromAX: rect, primaryScreenHeight: primary.frame.height)
        )
    }
}
