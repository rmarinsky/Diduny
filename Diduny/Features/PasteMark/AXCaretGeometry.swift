import AppKit
import ApplicationServices

/// The focused element's caret through AX: the character before the insertion point
/// (the end of a selection when there is one). Never reads the text itself.
struct AXCaretGeometry: CaretGeometry {
    func caret() -> CaretPosition? {
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
              AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) // swiftlint:disable:this force_cast
        else { return nil }

        let end = range.location + range.length
        guard end > 0 else { return nil }
        var before = CFRange(location: end - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &before) else { return nil }

        var boundsRef: CFTypeRef?
        var rect = CGRect.zero
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &boundsRef
        ) == .success,
            let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID(),
            AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), // swiftlint:disable:this force_cast
            let primary = NSScreen.screens.first,
            let plausible = PasteMarkPlan.plausibleCaretRect(
                InplaceTranslationAnchor.appKitRect(fromAX: rect, primaryScreenHeight: primary.frame.height)
            )
        else { return nil }
        return CaretPosition(location: end, rect: plausible)
    }
}
