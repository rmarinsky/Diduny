import CoreGraphics
import Foundation

enum AutoFixKeyEventText {
    static func sanitized(_ text: String) -> String {
        text.unicodeScalars.reduce(into: "") { result, scalar in
            if !CharacterSet.controlCharacters.contains(scalar)
                || scalar.value == 9
                || scalar.value == 10
                || scalar.value == 13 {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    /// Whether a keystroke types over an open proposal (demoting it to a chip)
    /// rather than just dismissing it. Tab, Return and other control keys move
    /// focus or act — they are not typing text over the word.
    static func typesOverProposal(_ text: String, flags: CGEventFlags) -> Bool {
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return false }
        return text.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) }
    }
}
