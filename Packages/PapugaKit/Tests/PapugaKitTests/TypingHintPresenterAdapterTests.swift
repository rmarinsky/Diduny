import AppKit
import XCTest
@testable import PapugaKit

@MainActor
private final class RecordingHost: TypingHintPresenting {
    var recoveries: [TypingRecoveryHint] = []
    var proposals: [TypingProposalHint] = []
    var proposalActions: TypingProposalActions?
    var dismissals: [TypingProposalOutcome?] = []
    var keys: [UInt16] = []

    func showFixToast(near _: NSPoint, onClick _: (() -> Void)?) {}
    func showRecovery(_ hint: TypingRecoveryHint, near _: NSPoint, onClick _: @escaping () -> Void) {
        recoveries.append(hint)
    }
    func showDeferredChip(
        original _: String, candidate _: String, near _: NSPoint, timeToLive _: TimeInterval,
        onApply _: @escaping () -> Void, onDismiss _: @escaping () -> Void, onExpire _: @escaping () -> Void
    ) {}
    func dismissChip() {}
    func dismissFixToast() {}
    func isMouseOverToast() -> Bool { false }
    func isMouseOverChip() -> Bool { false }
    func showProposal(_ hint: TypingProposalHint, near _: NSPoint, duration _: TimeInterval, actions: TypingProposalActions) {
        proposals.append(hint)
        proposalActions = actions
    }
    func dismissProposal(outcome: TypingProposalOutcome?) { dismissals.append(outcome) }
    func handleProposalKeyboardShortcut(keyCode: UInt16, flags _: CGEventFlags) -> Bool {
        keys.append(keyCode)
        return true
    }
    func isMouseOverProposal() -> Bool { true }
}

@MainActor
final class TypingHintPresenterAdapterTests: XCTestCase {
    private let host = RecordingHost()
    private lazy var adapter = TypingHintPresenterAdapter(host: host)

    func test_proposalKindsBecomeTheHostsTwoTitlesAndTheRuleFlag() {
        let expected: [(AutoFixProposal.Kind, TypingProposalHint.Kind, Bool)] = [
            (.detected, .replacement, true),
            (.customRule, .replacement, false),
            (.spelling, .correction, false),
            (.compound, .correction, false)
        ]
        for (kind, hintKind, createsRule) in expected {
            let hint = TypingProposalHint(makeProposal(kind: kind))
            XCTAssertEqual(
                hint,
                TypingProposalHint(kind: hintKind, original: "ghbds", candidate: "привіт", createsRuleOnAcceptance: createsRule)
            )
        }
    }

    func test_everyProposalActionReachesTheHostUnchanged() {
        var called: [String] = []
        adapter.showProposal(
            proposal: makeProposal(kind: .detected),
            near: .zero,
            duration: 5,
            actions: AutoFixProposalActions(
                replace: { called.append("replace") },
                dismiss: { called.append("dismiss") },
                typedOver: { called.append("typedOver") },
                timedOut: { called.append("timedOut") },
                neverReplace: { called.append("neverReplace") }
            )
        )
        let actions = host.proposalActions
        actions?.replace()
        actions?.dismiss()
        actions?.typedOver()
        actions?.timedOut()
        actions?.neverReplace()
        XCTAssertEqual(called, ["replace", "dismiss", "typedOver", "timedOut", "neverReplace"])
    }

    func test_dismissOutcomesAndKeysPassThrough() {
        for outcome in [AutoFixProposalOutcome.accepted, .dismissed, .typedOver, .timedOut, .neverReplace] {
            adapter.dismissProposal(outcome: outcome)
        }
        adapter.dismissProposal(outcome: nil)
        XCTAssertEqual(host.dismissals, [.accepted, .dismissed, .typedOver, .timedOut, .neverReplace, nil])

        XCTAssertTrue(adapter.handleProposalKeyboardShortcut(keyCode: 0x35, flags: []))
        XCTAssertEqual(host.keys, [0x35])
        XCTAssertTrue(adapter.isMouseOverProposal())
    }

    func test_recoveryTitlesBecomeTheTwoHints() {
        adapter.showRecovery(title: AutoFixRecoveryTitle.bringBackProposal, near: .zero) {}
        adapter.showRecovery(title: AutoFixRecoveryTitle.applyAgain, near: .zero) {}
        XCTAssertEqual(host.recoveries, [.bringBackProposal, .applyAgain])
    }

    func test_publicGateIsTheGateTheTapReads() {
        TypingProposalKeyGate.arm()
        XCTAssertTrue(AutoFixProposalShortcutGate.shared.isArmed)
        TypingProposalKeyGate.disarm()
        XCTAssertFalse(AutoFixProposalShortcutGate.shared.isArmed)
        XCTAssertFalse(TypingProposalKeyGate.isArmed)
    }

    private func makeProposal(kind: AutoFixProposal.Kind) -> AutoFixProposal {
        AutoFixProposal(
            original: "ghbds",
            candidate: "привіт",
            boundary: " ",
            fromLayoutID: "en",
            targetLayoutID: "uk",
            scoreOriginal: 0.1,
            scoreCandidate: 0.4,
            threshold: 0.35,
            algorithm: .appleNL,
            currentLang: "en",
            targetLang: "uk",
            bundleID: "com.example.app",
            createdAt: 0,
            replacementAnchor: TextReplacementAnchor(
                targetPID: 10,
                bundleID: "com.example.app",
                focusedElementIdentity: FocusedElementSignature.StableIdentity(
                    pid: 10, role: "AXTextArea", subrole: nil, windowTitleHash: nil, elementIdentifier: nil, frameHash: nil
                ),
                sourceRange: AXTextRange(location: 0, length: 5),
                boundaryUTF16Length: 1,
                caretAfterBoundary: 6,
                expectedSource: "ghbds",
                allowsKeyboardFallback: false
            ),
            kind: kind
        )
    }
}
