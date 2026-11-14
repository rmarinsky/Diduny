import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Short-lived readback proof for learning from a manual conversion. Never persisted.
/// Failure does not claim the paste failed; it means its outcome cannot teach the model.
struct ManualReplacementSnapshot {
    private let element: AXUIElement
    private let before: String
    private let range: NSRange
    private let original: String

    static func capture(original: String) -> Self? {
        guard !IsSecureEventInputEnabled(), let element = focusedElement(),
              attribute(kAXSubroleAttribute, of: element) as? String != "AXSecureTextField",
              let before = attribute(kAXValueAttribute, of: element) as? String,
              before.utf16.count <= 65_536,
              let range = selectedRange(of: element),
              let swiftRange = Range(range, in: before), String(before[swiftRange]) == original
        else { return nil }
        return Self(element: element, before: before, range: range, original: original)
    }

    func confirms(replacement: String) -> Bool {
        guard !IsSecureEventInputEnabled(), let focused = Self.focusedElement(), CFEqual(element, focused),
              let after = Self.attribute(kAXValueAttribute, of: element) as? String,
              let selection = Self.selectedRange(of: element), selection.length == 0 else { return false }
        return Self.confirms(before: before, range: range, original: original,
                             replacement: replacement, after: after, caret: selection.location)
    }

    static func confirms(before: String, range: NSRange, original: String, replacement: String,
                         after: String, caret: Int) -> Bool {
        guard range.location >= 0, range.length > 0, range.location <= before.utf16.count,
              range.length <= before.utf16.count - range.location,
              let selected = Range(range, in: before), String(before[selected]) == original,
              original != replacement, caret == range.location + replacement.utf16.count else { return false }
        if selected.lowerBound > before.startIndex,
           isWordContinuation(before[before.index(before: selected.lowerBound)]),
           original.first.map(isWordContinuation) == true { return false }
        if selected.upperBound < before.endIndex, isWordContinuation(before[selected.upperBound]),
           original.last.map(isWordContinuation) == true { return false }
        return before.replacingCharacters(in: selected, with: replacement) == after
    }

    private static func isWordContinuation(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_-'’ʼ".contains(character)
    }

    private static func focusedElement() -> AXUIElement? {
        guard let value = attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
