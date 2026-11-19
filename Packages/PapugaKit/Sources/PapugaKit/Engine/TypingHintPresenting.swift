import AppKit
import CoreGraphics
import Foundation

// The public side of the cursor UI. `AutoFixPresenting` stays internal because its proposal type
// drags in the scorer, the layout IDs and the replacement anchor; a host sees only plain values.

/// What the proposal panel shows.
public struct TypingProposalHint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A wrong-layout word or a custom rule: "possible replacement".
        case replacement
        /// A spelling fix or a compound: "possible fix".
        case correction
    }

    public let kind: Kind
    public let original: String
    public let candidate: String
    /// Accepting also saves a rule for this word.
    public let createsRuleOnAcceptance: Bool

    public init(kind: Kind, original: String, candidate: String, createsRuleOnAcceptance: Bool) {
        self.kind = kind
        self.original = original
        self.candidate = candidate
        self.createsRuleOnAcceptance = createsRuleOnAcceptance
    }
}

public enum TypingProposalOutcome: Equatable, Sendable {
    case accepted
    case dismissed
    /// The user kept typing while the panel was up.
    case typedOver
    case timedOut
    case neverReplace
}

/// One closure per outcome. The presenter calls the matching one once, after it hid the panel.
public struct TypingProposalActions {
    public var replace: () -> Void
    public var dismiss: () -> Void
    public var typedOver: () -> Void
    public var timedOut: () -> Void
    public var neverReplace: () -> Void

    public init(
        replace: @escaping () -> Void,
        dismiss: @escaping () -> Void,
        typedOver: @escaping () -> Void,
        timedOut: @escaping () -> Void,
        neverReplace: @escaping () -> Void
    ) {
        self.replace = replace
        self.dismiss = dismiss
        self.typedOver = typedOver
        self.timedOut = timedOut
        self.neverReplace = neverReplace
    }
}

public enum TypingRecoveryHint: Equatable, Sendable {
    /// A proposal was closed or timed out; a click opens it again.
    case bringBackProposal
    /// A fix was undone; a click applies it again.
    case applyAgain
}

/// While armed, the engine's key tap swallows Return, keypad Enter and Escape (without Command,
/// Control or Option) for every app and hands them to the presenter. Arm it only while the
/// proposal panel is on screen and disarm it on every path that hides the panel.
public enum TypingProposalKeyGate {
    public static var isArmed: Bool { AutoFixProposalShortcutGate.shared.isArmed }
    public static func arm() { AutoFixProposalShortcutGate.shared.arm() }
    public static func disarm() { AutoFixProposalShortcutGate.shared.disarm() }
}

/// Everything the engine shows near the cursor. Called on the main actor. `point` is in AppKit
/// screen coordinates.
@MainActor
public protocol TypingHintPresenting: AnyObject {
    /// The hint after a fix. `onClick` undoes the fix; nil means the fix cannot be undone.
    func showFixToast(near point: NSPoint, onClick: (() -> Void)?)
    /// The hint after Convert swapped a selection to the other layout. No undo of its own.
    func showSwapHint(near point: NSPoint)
    func showRecovery(_ hint: TypingRecoveryHint, near point: NSPoint, onClick: @escaping () -> Void)
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

    /// Shows the proposal panel for `duration` seconds, then calls `actions.timedOut`.
    func showProposal(_ hint: TypingProposalHint, near point: NSPoint, duration: TimeInterval, actions: TypingProposalActions)
    /// With an outcome: if the panel is visible, hide it and call the matching action once.
    /// With nil: hide it and call nothing.
    func dismissProposal(outcome: TypingProposalOutcome?)
    /// Return or keypad Enter accepts, Escape dismisses, when the panel is visible and no
    /// Command, Control or Option is held. Returns whether the key was handled.
    func handleProposalKeyboardShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool
    func isMouseOverProposal() -> Bool
}

public extension TypingHintPresenting {
    /// Hosts without a swap hint of their own show the fix hint without an undo.
    func showSwapHint(near point: NSPoint) {
        showFixToast(near: point, onClick: nil)
    }
}

/// Turns the controller's internal presenter calls into the host's plain-value ones.
@MainActor
final class TypingHintPresenterAdapter: AutoFixPresenting {
    private let host: TypingHintPresenting

    init(host: TypingHintPresenting) {
        self.host = host
    }

    func showFixToast(near point: NSPoint, onClick: (() -> Void)?) {
        host.showFixToast(near: point, onClick: onClick)
    }

    func showRecovery(title: String, near point: NSPoint, onClick: @escaping () -> Void) {
        host.showRecovery(TypingRecoveryHint(engineTitle: title), near: point, onClick: onClick)
    }

    func showDeferredChip(
        original: String,
        candidate: String,
        near point: NSPoint,
        timeToLive: TimeInterval,
        onApply: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onExpire: @escaping () -> Void
    ) {
        host.showDeferredChip(
            original: original, candidate: candidate, near: point, timeToLive: timeToLive,
            onApply: onApply, onDismiss: onDismiss, onExpire: onExpire
        )
    }

    func dismissChip() { host.dismissChip() }
    func dismissFixToast() { host.dismissFixToast() }
    func isMouseOverToast() -> Bool { host.isMouseOverToast() }
    func isMouseOverChip() -> Bool { host.isMouseOverChip() }

    func showProposal(
        proposal: AutoFixProposal,
        near point: NSPoint,
        duration: TimeInterval,
        actions: AutoFixProposalActions
    ) {
        host.showProposal(
            TypingProposalHint(proposal),
            near: point,
            duration: duration,
            actions: TypingProposalActions(
                replace: actions.replace, dismiss: actions.dismiss, typedOver: actions.typedOver,
                timedOut: actions.timedOut, neverReplace: actions.neverReplace
            )
        )
    }

    func dismissProposal(outcome: AutoFixProposalOutcome?) {
        host.dismissProposal(outcome: outcome.map(TypingProposalOutcome.init))
    }

    func handleProposalKeyboardShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        host.handleProposalKeyboardShortcut(keyCode: keyCode, flags: flags)
    }

    func isMouseOverProposal() -> Bool { host.isMouseOverProposal() }
}

extension TypingProposalHint {
    init(_ proposal: AutoFixProposal) {
        self.init(
            // Same split as Papuga's `displayTitle` and `neverActionTitle`.
            kind: proposal.kind == .spelling || proposal.kind == .compound ? .correction : .replacement,
            original: proposal.original,
            candidate: proposal.candidate,
            createsRuleOnAcceptance: proposal.createsRuleOnAcceptance
        )
    }
}

extension TypingProposalOutcome {
    init(_ outcome: AutoFixProposalOutcome) {
        switch outcome {
        case .accepted: self = .accepted
        case .dismissed: self = .dismissed
        case .typedOver: self = .typedOver
        case .timedOut: self = .timedOut
        case .neverReplace: self = .neverReplace
        }
    }
}

extension TypingRecoveryHint {
    /// The controller names a recovery by its Papuga title.
    init(engineTitle: String) {
        self = engineTitle == AutoFixRecoveryTitle.applyAgain ? .applyAgain : .bringBackProposal
    }
}
