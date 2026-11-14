import Carbon.HIToolbox
import Foundation

/// Guards auto-fix against corrupting text the user is *editing* rather than typing fresh.
///
/// The word buffer is a naive append-only accumulator with no document-position awareness, so when
/// the user moves the caret into existing text (arrow keys) or deletes back into it (backspace on an
/// empty buffer), the buffer no longer matches the on-screen word and a replacement would delete the
/// wrong characters. To stay safe we suppress the first token after those signals. Its boundary
/// re-synchronizes the buffer, so subsequent tokens are fresh input and can be evaluated normally.
struct AutoFixEditingGuard {
    private(set) var shouldSuppressCurrentToken = false

    mutating func reset() {
        shouldSuppressCurrentToken = false
    }

    /// Backspacing while the typing buffer is empty deletes into pre-existing text — the user is
    /// editing existing content, so suppress the next token.
    mutating func noteBackspace(bufferWasEmpty: Bool, enabled: Bool) {
        guard enabled, bufferWasEmpty else { return }
        noteEditingStarted()
    }

    /// Navigation keys (arrows, Home/End, Page Up/Down) move the caret into existing text.
    mutating func noteResetKey(_ keyCode: UInt16, enabled: Bool) {
        guard enabled, Self.isNavigationKey(keyCode) else { return }
        noteEditingStarted()
    }

    /// Marks that the next completed token must be skipped.
    mutating func noteEditingStarted() {
        shouldSuppressCurrentToken = true
    }

    /// A mouse click may land inside existing text, so suppress the very next word (the one the
    /// user starts typing from the clicked position).
    mutating func noteClickSuppression() {
        shouldSuppressCurrentToken = true
    }

    /// Non-destructive check used at the word boundary.
    func shouldSuppress(enabled: Bool) -> Bool {
        enabled && shouldSuppressCurrentToken
    }

    /// The first boundary re-synchronizes the append-only word buffer with the editor.
    mutating func noteBoundary() {
        shouldSuppressCurrentToken = false
    }

    static func isNavigationKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return true
        default:
            return false
        }
    }
}
