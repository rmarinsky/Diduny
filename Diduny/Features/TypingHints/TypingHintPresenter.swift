import AppKit
import PapugaKit

/// What one hint panel draws, with the closures its buttons call.
enum TypingHintContent {
    /// The hint after a fix. `onClick` nil: the fix cannot be undone and the panel takes no clicks.
    case undo(onClick: (() -> Void)?)
    case recovery(TypingRecoveryHint, onClick: () -> Void)
    case chip(original: String, candidate: String, timeToLive: TimeInterval, onApply: () -> Void, onDismiss: () -> Void)
    case proposal(TypingProposalHint, onReplace: () -> Void, onDismiss: () -> Void, onNeverReplace: () -> Void)
}

/// One floating panel; `TypingHintPanel` in the app, a fake in tests.
@MainActor
protocol TypingHintSurface: AnyObject {
    var isVisible: Bool { get }
    /// The mouse pointer is inside the panel's frame.
    var containsMouse: Bool { get }
    func show(_ content: TypingHintContent, near point: NSPoint)
    func hide()
}

/// The typing engine's hints near the cursor: the undo hint, the recovery hint, the deferred chip
/// and the proposal. The moments, durations and hide paths are Papuga's `FixToastCoordinator` and
/// `AutoFixProposalCoordinator`; only the panels' look is Diduny's.
@MainActor
final class TypingHintPresenter: TypingHintPresenting {
    /// Papuga's defaults.
    nonisolated static let undoHintDuration: TimeInterval = 2.5
    nonisolated static let recoveryDuration: TimeInterval = 10

    /// The undo hint and the recovery hint share one panel, so quick fixes do not pile up.
    private let toast: TypingHintSurface
    /// The chip has its own panel and lifetime: the toast is dismissed on every key, and the chip
    /// has to survive typing.
    private let chip: TypingHintSurface
    private let proposal: TypingHintSurface
    private let isUndoHintEnabled: () -> Bool
    private let undoHintDuration: TimeInterval
    private let recoveryDuration: TimeInterval
    /// Arms or disarms the key gate of the engine's tap. Sendable, so `deinit` can call it.
    private let setGateArmed: @Sendable (Bool) -> Void

    private var toastTask: Task<Void, Never>?
    private var toastTakesClicks = false
    private var chipTask: Task<Void, Never>?
    private var proposalTask: Task<Void, Never>?
    private var proposalActions: TypingProposalActions?

    init(
        toast: TypingHintSurface,
        chip: TypingHintSurface,
        proposal: TypingHintSurface,
        isUndoHintEnabled: @escaping () -> Bool,
        undoHintDuration: TimeInterval = TypingHintPresenter.undoHintDuration,
        recoveryDuration: TimeInterval = TypingHintPresenter.recoveryDuration,
        setGateArmed: @escaping @Sendable (Bool) -> Void = { $0 ? TypingProposalKeyGate.arm() : TypingProposalKeyGate.disarm() }
    ) {
        self.toast = toast
        self.chip = chip
        self.proposal = proposal
        self.isUndoHintEnabled = isUndoHintEnabled
        self.undoHintDuration = undoHintDuration
        self.recoveryDuration = recoveryDuration
        self.setGateArmed = setGateArmed
    }

    /// The app's presenter, on real panels.
    convenience init(settings: SettingsStorage = .shared) {
        self.init(
            toast: TypingHintPanel(),
            chip: TypingHintPanel(),
            proposal: TypingHintPanel(),
            isUndoHintEnabled: { settings.typingUndoHintEnabled }
        )
    }

    deinit {
        // An armed gate with no presenter would swallow Return and Escape in every app.
        setGateArmed(false)
        toastTask?.cancel()
        chipTask?.cancel()
        proposalTask?.cancel()
    }

    // MARK: - Undo hint and recovery hint

    func showFixToast(near point: NSPoint, onClick: (() -> Void)?) {
        // The engine checks the same setting; this keeps the hint off even if it did not.
        guard isUndoHintEnabled() else { return }
        toastTask?.cancel()
        toastTakesClicks = onClick != nil
        toast.show(.undo(onClick: onClick.map { action in
            { [weak self] in
                self?.dismissFixToast()
                action()
            }
        }), near: point)
        toastTask = after(undoHintDuration) { $0.dismissFixToast() }
    }

    func showRecovery(_ hint: TypingRecoveryHint, near point: NSPoint, onClick: @escaping () -> Void) {
        toastTask?.cancel()
        toastTakesClicks = true
        toast.show(.recovery(hint) { [weak self] in
            self?.dismissFixToast()
            onClick()
        }, near: point)
        toastTask = after(recoveryDuration) { $0.dismissFixToast() }
    }

    func dismissFixToast() {
        toastTask?.cancel()
        toastTask = nil
        toast.hide()
    }

    /// The engine asks this before it treats a mouse click as "the user moved on": a click on the
    /// hint itself must still find the pending undo.
    func isMouseOverToast() -> Bool {
        toast.isVisible && toastTakesClicks && toast.containsMouse
    }

    // MARK: - Deferred chip

    func showDeferredChip(
        original: String,
        candidate: String,
        near point: NSPoint,
        timeToLive: TimeInterval,
        onApply: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onExpire: @escaping () -> Void
    ) {
        chipTask?.cancel()
        chip.show(.chip(
            original: original,
            candidate: candidate,
            timeToLive: timeToLive,
            onApply: { [weak self] in
                self?.dismissChip()
                onApply()
            },
            onDismiss: { [weak self] in
                self?.dismissChip()
                onDismiss()
            }
        ), near: point)
        chipTask = after(timeToLive) {
            $0.dismissChip()
            onExpire()
        }
    }

    func dismissChip() {
        chipTask?.cancel()
        chipTask = nil
        chip.hide()
    }

    func isMouseOverChip() -> Bool {
        chip.isVisible && chip.containsMouse
    }

    // MARK: - Proposal

    func showProposal(_ hint: TypingProposalHint, near point: NSPoint, duration: TimeInterval, actions: TypingProposalActions) {
        proposalTask?.cancel()
        proposalActions = actions
        proposal.show(.proposal(
            hint,
            onReplace: { [weak self] in self?.completeProposal(.accepted) },
            onDismiss: { [weak self] in self?.completeProposal(.dismissed) },
            onNeverReplace: { [weak self] in self?.completeProposal(.neverReplace) }
        ), near: point)
        setGateArmed(true)
        proposalTask = after(duration) { $0.completeProposal(.timedOut) }
    }

    func dismissProposal(outcome: TypingProposalOutcome?) {
        if let outcome {
            completeProposal(outcome)
        } else {
            hideProposal()
        }
    }

    func handleProposalKeyboardShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard proposal.isVisible else {
            hideProposal()
            return false
        }
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) else {
            return false
        }
        switch keyCode {
        case 0x24, 0x4C: // Return, keypad Enter
            completeProposal(.accepted)
            return true
        case 0x35: // Escape
            completeProposal(.dismissed)
            return true
        default:
            return false
        }
    }

    func isMouseOverProposal() -> Bool {
        proposal.isVisible && proposal.containsMouse
    }

    private func completeProposal(_ outcome: TypingProposalOutcome) {
        guard proposal.isVisible, let actions = proposalActions else {
            // Nothing on screen. If the panel went away without us (Papuga kept the gate armed
            // here), this takes the gate down with it.
            hideProposal()
            return
        }
        hideProposal()
        switch outcome {
        case .accepted: actions.replace()
        case .dismissed: actions.dismiss()
        case .typedOver: actions.typedOver()
        case .timedOut: actions.timedOut()
        case .neverReplace: actions.neverReplace()
        }
    }

    /// The only way the proposal leaves the screen, so the gate is never left armed.
    private func hideProposal() {
        proposalTask?.cancel()
        proposalTask = nil
        proposalActions = nil
        setGateArmed(false)
        proposal.hide()
    }

    private func after(_ seconds: TimeInterval, _ action: @escaping @MainActor (TypingHintPresenter) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self else { return }
            action(self)
        }
    }
}
