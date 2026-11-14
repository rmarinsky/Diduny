import AppKit
import CoreGraphics
import Foundation
import os

// The seams between `AutoFixController` and its host app. In Papuga these were the settings
// store, two cursor-UI coordinators, the counters and the word-list service, all reached as
// singletons. The host implements the protocols; the package ships no UI.

// MARK: - Settings the controller writes

/// One method per setting the controller itself persists. Called on the main actor. Each call
/// must take effect before it returns: the next read of the settings provider has to see it.
@MainActor
protocol TypingSettingsWriting: AnyObject {
    /// Papuga key `typingCadenceAverageGap`. Called from `AutoFixController.stop()`.
    func setTypingCadenceAverageGap(_ gap: Double)
    /// Papuga key `customAutoReplaceRules`. Called when an accepted proposal becomes a rule;
    /// `rules` is the complete new list.
    func setCustomAutoReplaceRules(_ rules: [CustomAutoReplaceRule])
}

// MARK: - Word list

/// The two calls the controller made on Papuga's word-list service.
@MainActor
protocol WordListEditing: AnyObject {
    /// "Never replace this word." In Papuga: add to `autoFixAllowlist`, remove the replacement
    /// rules for it, and teach it to the system spelling dictionary.
    func add(_ rawWord: String)
    /// Takes back an earlier `add`: remove from `autoFixAllowlist` and unlearn the spelling
    /// Papuga taught.
    func remove(_ rawWord: String)
}

// MARK: - Counters

/// The user-facing replacement counters. Same methods and parameters as Papuga's counters.
@MainActor
protocol TypingStatsRecording: AnyObject {
    func recordReplacement(text: String)
    /// Reverses a previous `recordReplacement` when the user undoes a fix.
    func reverseReplacement(text: String)
}

// MARK: - Undo shortcut

/// The host's "undo the last fix" shortcut in Carbon terms, or nil from the provider when no
/// shortcut is set.
struct AutoFixUndoShortcut: Equatable {
    var carbonKeyCode: Int
    var modifiers: NSEvent.ModifierFlags
}

// MARK: - Cursor UI

struct AutoFixProposalActions {
    var replace: () -> Void
    var dismiss: () -> Void
    var typedOver: () -> Void
    var timedOut: () -> Void
    var neverReplace: () -> Void
}

/// Thread-safe mirror of "is a proposal currently on screen and listening for Return/Escape".
/// The AutoFix event tap (running on its own thread) reads `isArmed` synchronously to decide
/// whether to even consider swallowing a keystroke, without hopping to the main actor.
/// The presenter arms it when the proposal panel appears and disarms it whenever the panel hides.
final class AutoFixProposalShortcutGate: @unchecked Sendable {
    static let shared = AutoFixProposalShortcutGate()
    private let armed = OSAllocatedUnfairLock(initialState: false)
    private init() {}

    var isArmed: Bool { armed.withLock { $0 } }
    func arm() { armed.withLock { $0 = true } }
    func disarm() { armed.withLock { $0 = false } }
}

/// The two recovery toasts the controller shows, by their Papuga titles.
enum AutoFixRecoveryTitle {
    static let bringBackProposal = "Повернути підказку"
    static let applyAgain = "Застосувати знову"
}

/// Everything the controller shows near the cursor. The methods mirror, one for one, the calls
/// the controller made on Papuga's toast coordinator and proposal coordinator.
@MainActor
protocol AutoFixPresenting: AnyObject {
    // Toast coordinator.

    /// The "fixed" toast. `onClick` undoes the fix; nil means the fix cannot be undone.
    func showFixToast(near point: NSPoint, onClick: (() -> Void)?)
    /// A recovery toast ("bring the hint back", "apply again"). Papuga shows it for 10 seconds.
    func showRecovery(title: String, near point: NSPoint, onClick: @escaping () -> Void)
    /// The passive chip a typed-over proposal demotes to. It must not take keyboard input.
    func showDeferredChip(
        original: String,
        candidate: String,
        near point: NSPoint,
        timeToLive: TimeInterval,
        onApply: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onExpire: @escaping () -> Void
    )
    func dismissChip()
    /// Hides the fix toast or the recovery toast. Does not hide the chip.
    func dismissFixToast()
    func isMouseOverToast() -> Bool
    func isMouseOverChip() -> Bool

    // Proposal coordinator.

    /// Shows the proposal panel for `duration` seconds, then calls `actions.timedOut`.
    /// Arm `AutoFixProposalShortcutGate.shared` here.
    func showProposal(
        proposal: AutoFixProposal,
        near point: NSPoint,
        duration: TimeInterval,
        actions: AutoFixProposalActions
    )
    /// With an outcome: if the panel is visible, hide it and call the matching action once.
    /// With nil: hide it and call nothing. Disarm `AutoFixProposalShortcutGate.shared` on every hide.
    func dismissProposal(outcome: AutoFixProposalOutcome?)
    /// Return or keypad Enter accepts, Escape dismisses, when the panel is visible and no
    /// Command, Control or Option is held. Returns whether the key was handled.
    func handleProposalKeyboardShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool
    func isMouseOverProposal() -> Bool
}

/// Shows nothing and never arms the shortcut gate. For tests and for a host without cursor UI.
@MainActor
final class NoOpAutoFixPresenter: AutoFixPresenting {
    init() {}

    func showFixToast(near _: NSPoint, onClick _: (() -> Void)?) {}
    func showRecovery(title _: String, near _: NSPoint, onClick _: @escaping () -> Void) {}
    func showDeferredChip(
        original _: String,
        candidate _: String,
        near _: NSPoint,
        timeToLive _: TimeInterval,
        onApply _: @escaping () -> Void,
        onDismiss _: @escaping () -> Void,
        onExpire _: @escaping () -> Void
    ) {}
    func dismissChip() {}
    func dismissFixToast() {}
    func isMouseOverToast() -> Bool { false }
    func isMouseOverChip() -> Bool { false }
    func showProposal(
        proposal _: AutoFixProposal,
        near _: NSPoint,
        duration _: TimeInterval,
        actions _: AutoFixProposalActions
    ) {}
    func dismissProposal(outcome _: AutoFixProposalOutcome?) {}
    func handleProposalKeyboardShortcut(keyCode _: UInt16, flags _: CGEventFlags) -> Bool { false }
    func isMouseOverProposal() -> Bool { false }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted after every replacement. Same name as in Papuga `Utilities/Constants.swift`.
    static let textReplacementDidComplete = Notification.Name("ua.com.rmarinsky.papuga.textReplacementDidComplete")
}
