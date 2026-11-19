import AppKit
import XCTest
@testable import PapugaKit

/// Builds an `AutoFixController` with in-memory collaborators. The tap is never started.
@MainActor
final class AutoFixControllerHarness {
    final class Writer: TypingSettingsWriting {
        var cadenceGaps: [Double] = []
        var ruleWrites: [[CustomAutoReplaceRule]] = []
        func setTypingCadenceAverageGap(_ gap: Double) { cadenceGaps.append(gap) }
        func setCustomAutoReplaceRules(_ rules: [CustomAutoReplaceRule]) { ruleWrites.append(rules) }
    }

    final class Stats: TypingStatsRecording {
        var recorded: [String] = []
        var reversed: [String] = []
        func recordReplacement(text: String) { recorded.append(text) }
        func reverseReplacement(text: String) { reversed.append(text) }
    }

    final class WordList: WordListEditing {
        var added: [String] = []
        var removed: [String] = []
        func add(_ rawWord: String) { added.append(rawWord) }
        func remove(_ rawWord: String) { removed.append(rawWord) }
    }

    final class Presenter: AutoFixPresenting {
        var proposalDismissals: [AutoFixProposalOutcome?] = []
        var toastDismissals = 0
        func showFixToast(near _: NSPoint, onClick _: (() -> Void)?) {}
        func showRecovery(title _: String, near _: NSPoint, onClick _: @escaping () -> Void) {}
        func showDeferredChip(
            original _: String, candidate _: String, near _: NSPoint, timeToLive _: TimeInterval,
            onApply _: @escaping () -> Void, onDismiss _: @escaping () -> Void, onExpire _: @escaping () -> Void
        ) {}
        func dismissChip() {}
        func dismissFixToast() { toastDismissals += 1 }
        func isMouseOverToast() -> Bool { false }
        func isMouseOverChip() -> Bool { false }
        func showProposal(proposal _: AutoFixProposal, near _: NSPoint, duration _: TimeInterval,
                          actions _: AutoFixProposalActions) {}
        func dismissProposal(outcome: AutoFixProposalOutcome?) { proposalDismissals.append(outcome) }
        func handleProposalKeyboardShortcut(keyCode _: UInt16, flags _: CGEventFlags) -> Bool { false }
        func isMouseOverProposal() -> Bool { false }
    }

    /// What the controller's providers read. Change a value and the controller sees it on its next read.
    final class Box {
        var settings: TypingSettings
        var undoShortcut: AutoFixUndoShortcut?
        var isSecureField = false
        init(settings: TypingSettings) { self.settings = settings }
    }

    private let box: Box
    var settings: TypingSettings {
        get { box.settings }
        set { box.settings = newValue }
    }
    var undoShortcut: AutoFixUndoShortcut? {
        get { box.undoShortcut }
        set { box.undoShortcut = newValue }
    }
    var isSecureField: Bool {
        get { box.isSecureField }
        set { box.isSecureField = newValue }
    }
    let writer = Writer()
    let stats = Stats()
    let wordList = WordList()
    let presenter = Presenter()
    let controller: AutoFixController

    init(directory: URL, decisionHistory: AutoFixDecisionRecording? = nil, settings: TypingSettings = TypingSettings()) {
        let box = Box(settings: settings)
        self.box = box
        controller = AutoFixController(
            layoutManager: LayoutManager(),
            characterMapper: CharacterMapper(),
            spellChecker: HybridSpellChecker(),
            decisionHistory: decisionHistory ?? AutoFixDecisionHistoryStore(directory: directory),
            replacementHistory: ReplacementHistoryStore(directory: directory),
            eventLog: PapugaEventLog(directory: directory),
            settings: { box.settings },
            settingsWriter: writer,
            presenter: presenter,
            stats: stats,
            wordList: wordList,
            undoShortcut: { box.undoShortcut },
            isSecureField: { box.isSecureField }
        )
    }
}
