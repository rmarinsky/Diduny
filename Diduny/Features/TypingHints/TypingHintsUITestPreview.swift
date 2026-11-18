#if TEST_BUILD
    import AppKit
    import PapugaKit

    /// `--ui-testing-typing-hints=x,y` shows every typing hint with sample text, stacked downwards
    /// from that screen point (AppKit coordinates), and keeps them up. The key gate is not touched.
    @MainActor
    enum TypingHintsUITestPreview {
        static let argument = "--ui-testing-typing-hints"
        private static var presenters: [TypingHintPresenter] = []

        static func showIfRequested() {
            guard let value = UITestHarness.value(of: argument) else { return }
            let parts = value.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            let hold: TimeInterval = 600
            let actions = TypingProposalActions(replace: {}, dismiss: {}, typedOver: {}, timedOut: {}, neverReplace: {})
            let rows: [(TypingHintPresenter, NSPoint) -> Void] = [
                { $0.showFixToast(near: $1) {} },
                { $0.showFixToast(near: $1, onClick: nil) },
                { $0.showRecovery(.bringBackProposal, near: $1) {} },
                { $0.showRecovery(.applyAgain, near: $1) {} },
                { $0.showDeferredChip(original: "ghbdsn", candidate: "привіт", near: $1, timeToLive: hold, onApply: {}, onDismiss: {}, onExpire: {}) },
                { $0.showProposal(
                    TypingProposalHint(kind: .replacement, original: "ghbdsn", candidate: "привіт", createsRuleOnAcceptance: true),
                    near: $1, duration: hold, actions: actions
                ) },
                { $0.showProposal(
                    TypingProposalHint(kind: .correction, original: "recieve the adress", candidate: "receive the address", createsRuleOnAcceptance: false),
                    near: $1, duration: hold, actions: actions
                ) }
            ]
            var y = parts[1]
            for (index, row) in rows.enumerated() {
                let presenter = TypingHintPresenter(
                    // At the given point, not at the focused text: the rows stay stacked.
                    toast: TypingHintPanel(textEnd: { nil }), chip: TypingHintPanel(), proposal: TypingHintPanel(),
                    isUndoHintEnabled: { true }, undoHintDuration: hold, receiptDuration: hold, recoveryDuration: hold,
                    setGateArmed: { _ in }
                )
                presenters.append(presenter)
                row(presenter, NSPoint(x: parts[0], y: y))
                y -= index < 5 ? 44 : 120
            }
        }
    }
#endif
