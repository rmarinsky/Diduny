import AppKit
@testable import Diduny
import os
import PapugaKit
import Testing

@MainActor
private final class FakeSurface: TypingHintSurface {
    var isVisible = false
    var containsMouse = false
    var shown: [TypingHintContent] = []
    var hides = 0

    func show(_ content: TypingHintContent, near _: NSPoint) {
        shown.append(content)
        isVisible = true
    }

    func hide() {
        hides += 1
        isVisible = false
    }

    /// Clicks the hint: the undo or recovery pill, or the chip's apply.
    func click() {
        switch shown.last {
        case let .undo(onClick): onClick?()
        case .swapped: break
        case let .recovery(_, onClick): onClick()
        case let .chip(_, _, _, onApply, _): onApply()
        case let .proposal(_, onReplace, _, _): onReplace()
        case nil: break
        }
    }
}

private final class GateRecorder: Sendable {
    private let armed = OSAllocatedUnfairLock(initialState: false)
    var isArmed: Bool { armed.withLock { $0 } }
    func set(_ value: Bool) { armed.withLock { $0 = value } }
}

/// Every way the proposal leaves the screen. The gate must be disarmed after each.
enum ProposalHidePath: String, CaseIterable, CustomTestStringConvertible {
    case returnKey, keypadEnterKey, escapeKey
    case replaceButton, closeButton, neverButton
    case engineAccepted, engineDismissed, engineTypedOver, engineTimedOut, engineNeverReplace
    case engineHidWithoutOutcome
    case timeout
    case panelLostThenKey, panelLostThenTyping
    case presenterDeinit

    var testDescription: String { rawValue }

    /// The action the engine must hear, nil when the panel goes silently.
    var expectedAction: String? {
        switch self {
        case .returnKey, .keypadEnterKey, .replaceButton, .engineAccepted: "replace"
        case .escapeKey, .closeButton, .engineDismissed: "dismiss"
        case .neverButton, .engineNeverReplace: "neverReplace"
        case .engineTypedOver: "typedOver"
        case .engineTimedOut, .timeout: "timedOut"
        case .engineHidWithoutOutcome, .panelLostThenKey, .panelLostThenTyping, .presenterDeinit: nil
        }
    }
}

@MainActor
final class TypingHintPresenterTests {
    private let toast = FakeSurface()
    private let chip = FakeSurface()
    private let proposal = FakeSurface()
    private let gate = GateRecorder()
    private var undoHintEnabled = true
    private var calls: [String] = []
    private let hint = TypingProposalHint(kind: .replacement, original: "ghbdsn", candidate: "привіт", createsRuleOnAcceptance: true)

    private func makePresenter(undoHintDuration: TimeInterval = 60, recoveryDuration: TimeInterval = 60) -> TypingHintPresenter {
        TypingHintPresenter(
            toast: toast, chip: chip, proposal: proposal,
            isUndoHintEnabled: { [unowned self] in undoHintEnabled },
            undoHintDuration: undoHintDuration, recoveryDuration: recoveryDuration,
            setGateArmed: { [gate] in gate.set($0) }
        )
    }

    private var actions: TypingProposalActions {
        TypingProposalActions(
            replace: { [unowned self] in calls.append("replace") },
            dismiss: { [unowned self] in calls.append("dismiss") },
            typedOver: { [unowned self] in calls.append("typedOver") },
            timedOut: { [unowned self] in calls.append("timedOut") },
            neverReplace: { [unowned self] in calls.append("neverReplace") }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Proposal and the key gate

    @Test("the gate is armed while the proposal is up and disarmed after every hide path", arguments: ProposalHidePath.allCases)
    func gateWalk(path: ProposalHidePath) async {
        var sut: TypingHintPresenter? = makePresenter()
        #expect(!gate.isArmed)

        sut?.showProposal(hint, near: .zero, duration: path == .timeout ? 0.02 : 60, actions: actions)
        #expect(gate.isArmed)
        #expect(proposal.isVisible)

        guard case let .proposal(_, onReplace, onDismiss, onNeverReplace)? = proposal.shown.last else {
            Issue.record("the proposal surface got no proposal")
            return
        }
        switch path {
        case .returnKey: #expect(sut?.handleProposalKeyboardShortcut(keyCode: 0x24, flags: []) == true)
        case .keypadEnterKey: #expect(sut?.handleProposalKeyboardShortcut(keyCode: 0x4C, flags: []) == true)
        case .escapeKey: #expect(sut?.handleProposalKeyboardShortcut(keyCode: 0x35, flags: []) == true)
        case .replaceButton: onReplace()
        case .closeButton: onDismiss()
        case .neverButton: onNeverReplace()
        case .engineAccepted: sut?.dismissProposal(outcome: .accepted)
        case .engineDismissed: sut?.dismissProposal(outcome: .dismissed)
        case .engineTypedOver: sut?.dismissProposal(outcome: .typedOver)
        case .engineTimedOut: sut?.dismissProposal(outcome: .timedOut)
        case .engineNeverReplace: sut?.dismissProposal(outcome: .neverReplace)
        case .engineHidWithoutOutcome: sut?.dismissProposal(outcome: nil)
        case .timeout: await waitUntil { !gate.isArmed }
        case .panelLostThenKey:
            proposal.isVisible = false
            #expect(sut?.handleProposalKeyboardShortcut(keyCode: 0x24, flags: []) == false)
        case .panelLostThenTyping:
            proposal.isVisible = false
            sut?.dismissProposal(outcome: .typedOver)
        case .presenterDeinit: sut = nil
        }

        #expect(!gate.isArmed)
        #expect(calls == [path.expectedAction].compactMap { $0 })
        if path != .presenterDeinit {
            #expect(!proposal.isVisible)
            // Once hidden, nothing fires again: not a late key, not a late dismiss, not the timer.
            #expect(sut?.handleProposalKeyboardShortcut(keyCode: 0x24, flags: []) == false)
            sut?.dismissProposal(outcome: .dismissed)
            #expect(calls.count == (path.expectedAction == nil ? 0 : 1))
            #expect(!gate.isArmed)
        }
    }

    @Test("with Command, Control or Option held, and for other keys, the proposal stays and nothing is handled")
    func keysThatAreNotForTheProposal() {
        let sut = makePresenter()
        sut.showProposal(hint, near: .zero, duration: 60, actions: actions)

        #expect(!sut.handleProposalKeyboardShortcut(keyCode: 0x24, flags: .maskCommand))
        #expect(!sut.handleProposalKeyboardShortcut(keyCode: 0x35, flags: .maskControl))
        #expect(!sut.handleProposalKeyboardShortcut(keyCode: 0x24, flags: .maskAlternate))
        #expect(!sut.handleProposalKeyboardShortcut(keyCode: 0x00, flags: []))

        #expect(proposal.isVisible)
        #expect(gate.isArmed)
        #expect(calls.isEmpty)
    }

    @Test("a second proposal replaces the first: one panel, the gate stays armed, only the new actions fire")
    func secondProposalReplacesTheFirst() {
        let sut = makePresenter()
        sut.showProposal(hint, near: .zero, duration: 60, actions: TypingProposalActions(
            replace: { Issue.record("the replaced proposal fired") }, dismiss: {}, typedOver: {}, timedOut: {}, neverReplace: {}
        ))
        sut.showProposal(hint, near: .zero, duration: 60, actions: actions)
        #expect(gate.isArmed)

        #expect(sut.handleProposalKeyboardShortcut(keyCode: 0x24, flags: []))
        #expect(calls == ["replace"])
        #expect(!gate.isArmed)
    }

    @Test("with no proposal on screen no key is handled and the gate is never armed by the other hints")
    func otherHintsLeaveTheGateAlone() {
        let sut = makePresenter()
        sut.showFixToast(near: .zero) {}
        sut.showRecovery(.applyAgain, near: .zero) {}
        sut.showDeferredChip(original: "a", candidate: "b", near: .zero, timeToLive: 60, onApply: {}, onDismiss: {}, onExpire: {})

        #expect(!gate.isArmed)
        #expect(!sut.handleProposalKeyboardShortcut(keyCode: 0x35, flags: []))
        #expect(!proposal.isVisible)
    }

    // MARK: - Logo hints (Roman, 2026-11-18)

    @Test("the swap hint takes no clicks and leaves after the receipt time, while the undo hint stays")
    func swapHintIsAReceipt() async {
        let sut = TypingHintPresenter(
            toast: toast, chip: chip, proposal: proposal, isUndoHintEnabled: { true },
            undoHintDuration: 60, receiptDuration: 0.02, recoveryDuration: 60, setGateArmed: { _ in }
        )
        sut.showSwapHint(near: .zero)
        guard case .swapped? = toast.shown.last else {
            Issue.record("the toast surface got no swap hint")
            return
        }
        toast.containsMouse = true
        #expect(!sut.isMouseOverToast())
        await waitUntil { !toast.isVisible }
        #expect(!toast.isVisible)

        sut.showFixToast(near: .zero) {}
        try? await Task.sleep(for: .milliseconds(80))
        #expect(toast.isVisible)
        #expect(sut.isMouseOverToast())
    }

    @Test("a fix that cannot be undone is a receipt too")
    func fixWithoutUndoIsAReceipt() async {
        let sut = TypingHintPresenter(
            toast: toast, chip: chip, proposal: proposal, isUndoHintEnabled: { true },
            undoHintDuration: 60, receiptDuration: 0.02, recoveryDuration: 60, setGateArmed: { _ in }
        )
        sut.showFixToast(near: .zero, onClick: nil)
        await waitUntil { !toast.isVisible }
        #expect(!toast.isVisible)
    }

    @Test("with hints off there is no swap hint")
    func swapHintFollowsTheSetting() {
        undoHintEnabled = false
        makePresenter().showSwapHint(near: .zero)
        #expect(toast.shown.isEmpty)
    }

    @Test("the logo hints say Swapped, Oops fixed or Undo fix and sit at the text; the others at the pointer")
    func logoHintWordsAndPlace() {
        #expect(TypingHintContent.swapped.title == String(localized: "Swapped"))
        #expect(TypingHintContent.undo(onClick: nil).title == String(localized: "Oops, fixed"))
        #expect(TypingHintContent.undo(onClick: {}).title == String(localized: "Undo fix"))
        #expect(TypingHintContent.swapped.placesAtText)
        #expect(TypingHintContent.undo(onClick: nil).placesAtText)
        #expect(!TypingHintContent.recovery(.applyAgain, onClick: {}).placesAtText)
        #expect(!TypingHintContent.swapped.takesClicks)
    }

    @Test("a logo hint's pill sits 6 pt right of the text end, centered on its line; without the text, at the pointer")
    func logoHintFrame() throws {
        let screen = try #require(NSScreen.screens.first)
        let visible = screen.visibleFrame
        let text = NSRect(x: visible.midX - 100, y: visible.midY, width: 8, height: 18)
        let size = NSSize(width: 140, height: LogoPill.height + 2 * LogoPill.margin)
        let pointer = NSPoint(x: visible.midX + 200, y: visible.midY - 200)

        let atText = TypingHintPlacement.frame(for: .swapped, near: pointer, textEnd: text, size: size, visibleFrame: visible)
        #expect(atText.minX + LogoPill.margin == text.maxX + InplaceTranslationAnchor.gap)
        #expect(atText.midY == text.midY)
        #expect(atText.size == size)

        let atPointer = TypingHintPlacement.frame(for: .swapped, near: pointer, textEnd: nil, size: size, visibleFrame: visible)
        #expect(atPointer.minX + LogoPill.margin == pointer.x + TypingHintPlacement.offsetX)
    }

    @Test("by default the presenter drives the gate the engine's tap reads")
    func defaultGateIsTheEngineGate() {
        let sut = TypingHintPresenter(toast: toast, chip: chip, proposal: proposal, isUndoHintEnabled: { true })
        sut.showProposal(hint, near: .zero, duration: 60, actions: actions)
        #expect(TypingProposalKeyGate.isArmed)
        sut.dismissProposal(outcome: nil)
        #expect(!TypingProposalKeyGate.isArmed)
    }

    // MARK: - Undo hint and recovery hint

    @Test("the undo hint shows, a click hides it and undoes once")
    func undoHintClick() {
        let sut = makePresenter()
        sut.showFixToast(near: .zero) { [unowned self] in calls.append("undo") }
        #expect(toast.isVisible)

        toast.containsMouse = true
        #expect(sut.isMouseOverToast())
        toast.click()

        #expect(calls == ["undo"])
        #expect(!toast.isVisible)
        #expect(!sut.isMouseOverToast())
    }

    @Test("a fix that cannot be undone shows a hint that takes no clicks")
    func undoHintWithoutUndo() {
        let sut = makePresenter()
        sut.showFixToast(near: .zero, onClick: nil)

        guard case .undo(onClick: nil)? = toast.shown.last else {
            Issue.record("expected the plain hint")
            return
        }
        #expect(!TypingHintContent.undo(onClick: nil).takesClicks)
        toast.containsMouse = true
        // The engine must not treat a click through it as a click on the hint.
        #expect(!sut.isMouseOverToast())
    }

    @Test("with typing.undoHintEnabled off the undo hint is not shown; the recovery hint still is")
    func undoHintSettingOff() {
        undoHintEnabled = false
        let sut = makePresenter()

        sut.showFixToast(near: .zero) {}
        #expect(toast.shown.isEmpty)
        #expect(!toast.isVisible)

        sut.showRecovery(.bringBackProposal, near: .zero) {}
        #expect(toast.isVisible)
    }

    @Test("the setting reaches both the engine's settings and the presenter")
    func undoHintSettingIsWired() {
        let box = IsolatedSettings("TypingHintPresenterTests")
        box.settings.typingUndoHintEnabled = false
        #expect(!box.settings.typingSettings.autoFixToastEnabled)

        let sut = TypingHintPresenter(toast: toast, chip: chip, proposal: proposal, isUndoHintEnabled: { box.settings.typingUndoHintEnabled })
        sut.showFixToast(near: .zero) {}
        #expect(!toast.isVisible)

        box.settings.typingUndoHintEnabled = true
        #expect(box.settings.typingSettings.autoFixToastEnabled)
        sut.showFixToast(near: .zero) {}
        #expect(toast.isVisible)
    }

    @Test("the undo hint and the recovery hint hide after their time")
    func toastTimesOut() async {
        let sut = makePresenter(undoHintDuration: 0.02, recoveryDuration: 0.02)
        sut.showFixToast(near: .zero) {}
        await waitUntil { !toast.isVisible }
        #expect(!toast.isVisible)

        sut.showRecovery(.bringBackProposal, near: .zero) { [unowned self] in calls.append("reopen") }
        #expect(toast.isVisible)
        await waitUntil { !toast.isVisible }
        #expect(!toast.isVisible)
        #expect(calls.isEmpty)
    }

    @Test("a new hint restarts the timer of the shared panel; dismissFixToast hides it and leaves the chip")
    func toastIsReplacedAndDismissed() async {
        let sut = makePresenter(undoHintDuration: 0.02)
        sut.showDeferredChip(original: "a", candidate: "b", near: .zero, timeToLive: 60, onApply: {}, onDismiss: {}, onExpire: {})
        sut.showFixToast(near: .zero) {}
        sut.showRecovery(.applyAgain, near: .zero) { [unowned self] in calls.append("reapply") }
        // The undo hint's 20 ms timer was cancelled: the recovery hint (60 s) is still up after it.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(toast.isVisible)

        toast.click()
        #expect(calls == ["reapply"])
        #expect(!toast.isVisible)

        sut.showFixToast(near: .zero) {}
        sut.dismissFixToast()
        #expect(!toast.isVisible)
        #expect(chip.isVisible)
    }

    // MARK: - Deferred chip

    @Test("the chip: a click applies, the cross dismisses, the time-to-live expires, each exactly once")
    func chipPaths() async {
        let sut = makePresenter()
        func show(timeToLive: TimeInterval = 60) {
            sut.showDeferredChip(
                original: "ghbdsn", candidate: "привіт", near: .zero, timeToLive: timeToLive,
                onApply: { [unowned self] in calls.append("apply") },
                onDismiss: { [unowned self] in calls.append("dismiss") },
                onExpire: { [unowned self] in calls.append("expire") }
            )
        }

        show()
        chip.containsMouse = true
        #expect(sut.isMouseOverChip())
        chip.click()
        #expect(calls == ["apply"])
        #expect(!chip.isVisible)
        #expect(!sut.isMouseOverChip())

        show()
        if case let .chip(_, _, _, _, onDismiss)? = chip.shown.last { onDismiss() }
        #expect(calls == ["apply", "dismiss"])
        #expect(!chip.isVisible)

        show(timeToLive: 0.02)
        await waitUntil { calls.count == 3 }
        #expect(calls == ["apply", "dismiss", "expire"])
        #expect(!chip.isVisible)

        // The engine's own dismiss (engine stopped, click elsewhere) calls nothing back.
        show(timeToLive: 0.02)
        sut.dismissChip()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(calls.count == 3)
        #expect(!chip.isVisible)
    }

    @Test("typing hides the proposal and the toast but not the chip")
    func chipSurvivesTyping() {
        let sut = makePresenter()
        sut.showDeferredChip(original: "a", candidate: "b", near: .zero, timeToLive: 60, onApply: {}, onDismiss: {}, onExpire: {})
        sut.showProposal(hint, near: .zero, duration: 60, actions: actions)
        sut.showFixToast(near: .zero) {}

        // What the engine does on every key.
        sut.dismissProposal(outcome: .typedOver)
        sut.dismissFixToast()

        #expect(chip.isVisible)
        #expect(!proposal.isVisible)
        #expect(!toast.isVisible)
        #expect(calls == ["typedOver"])
    }

    // MARK: - Placement and text

    @Test("a hint sits right of and below the point and stays on the visible screen")
    func placement() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 200, height: 32)

        #expect(TypingHintPlacement.origin(near: NSPoint(x: 400, y: 400), size: size, gap: 6, visibleFrame: screen) == NSPoint(x: 414, y: 362))
        // Right edge and bottom edge.
        #expect(TypingHintPlacement.origin(near: NSPoint(x: 990, y: 10), size: size, gap: 6, visibleFrame: screen) == NSPoint(x: 792, y: 8))
        // Left of the screen and above it.
        #expect(TypingHintPlacement.origin(near: NSPoint(x: -500, y: 900), size: size, gap: 8, visibleFrame: screen) == NSPoint(x: 8, y: 760))
    }

    @Test("every hint has a panel label for VoiceOver")
    func labels() {
        let contents: [TypingHintContent] = [
            .undo(onClick: {}), .undo(onClick: nil), .recovery(.bringBackProposal, onClick: {}), .recovery(.applyAgain, onClick: {}),
            .chip(original: "a", candidate: "b", timeToLive: 1, onApply: {}, onDismiss: {}),
            .proposal(hint, onReplace: {}, onDismiss: {}, onNeverReplace: {})
        ]
        for content in contents {
            #expect(!content.title.isEmpty)
            #expect(!content.announcement.isEmpty)
        }
        #expect(Set(contents.map(\.title)).count == contents.count)
        #expect(hint.neverTitle.contains("ghbdsn"))
        #expect(hint.receiptLabel.contains("ghbdsn") && hint.receiptLabel.contains("привіт"))
    }
}
