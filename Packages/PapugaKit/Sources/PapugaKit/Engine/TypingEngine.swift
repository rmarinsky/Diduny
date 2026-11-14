import Foundation

/// The one type a host app uses. It builds the stores, the layout manager, the spell checker and
/// the controller in Papuga's start order. It draws nothing itself: the host's `hintPresenter`
/// shows the hints. Without one no proposal appears and the tap never swallows a key.
@MainActor
public final class TypingEngine {
    private let settings: @MainActor () -> TypingSettings
    private let hostCalls: HostCalls
    let replacementHistory: ReplacementHistoryStore
    let decisionHistory: AutoFixDecisionHistoryStore
    let eventLog: PapugaEventLog
    private let controller: AutoFixController
    private let layoutManager: LayoutManager
    private let characterMapper = CharacterMapper()

    /// True between a `start()` that returned true and the next `stop()`.
    public private(set) var isRunning = false

    /// - Parameters:
    ///   - storageDirectory: where the history and event files live. Created when missing.
    ///   - settings: read on the main actor every time the engine needs a setting, so keep it cheap.
    ///   - logSubsystem: the OSLog subsystem of the host.
    ///   - hintPresenter: shows the undo hint, the proposal, the recovery hint and the deferred chip.
    ///   - undoShortcut: the keys of the host's hotkey that calls `undoLastFix()`, read on every key
    ///     down. The key tap sees those keys before the hotkey fires and must not drop the pending fix.
    ///   - onCadenceGapWritten: the typing rhythm to keep for the next launch, written in `stop()`.
    ///     The next `settings()` should return it as `typingCadenceAverageGap`.
    ///   - onRulesWritten: the complete new rule list. The next `settings()` must return it as
    ///     `customAutoReplaceRules`.
    ///   - onWordAdded: "never replace this word". The next `settings()` must return it in
    ///     `autoFixAllowlist`. `onWordRemoved` takes that back.
    public init(
        storageDirectory: URL,
        settings: @escaping @MainActor () -> TypingSettings,
        logSubsystem: String,
        hintPresenter: TypingHintPresenting? = nil,
        undoShortcut: @escaping @MainActor () -> AutoFixUndoShortcut? = { nil },
        onReplacementRecorded: ((String) -> Void)? = nil,
        onReplacementReversed: ((String) -> Void)? = nil,
        onCadenceGapWritten: ((Double) -> Void)? = nil,
        onRulesWritten: (([CustomAutoReplaceRule]) -> Void)? = nil,
        onWordAdded: ((String) -> Void)? = nil,
        onWordRemoved: ((String) -> Void)? = nil
    ) {
        self.settings = settings
        hostCalls = HostCalls(
            onReplacementRecorded: onReplacementRecorded,
            onReplacementReversed: onReplacementReversed,
            onCadenceGapWritten: onCadenceGapWritten,
            onRulesWritten: onRulesWritten,
            onWordAdded: onWordAdded,
            onWordRemoved: onWordRemoved
        )
        AppLogger.subsystem = logSubsystem
        let initial = settings()

        // Same order as Papuga's app delegate: event log, the two histories, n-grams, controller.
        eventLog = PapugaEventLog(directory: storageDirectory)
        eventLog.pruneOldEntries()
        replacementHistory = ReplacementHistoryStore(directory: storageDirectory, logSubsystem: logSubsystem)
        decisionHistory = AutoFixDecisionHistoryStore(directory: storageDirectory, logSubsystem: logSubsystem)
        NGramScorer.prepare()
        layoutManager = LayoutManager(layoutOrder: initial.layoutOrder, disabledLayouts: initial.disabledLayouts)
        controller = AutoFixController(
            layoutManager: layoutManager,
            characterMapper: characterMapper,
            spellChecker: HybridSpellChecker.production(
                allowlist: initial.autoFixAllowlist,
                rules: initial.customAutoReplaceRules
            ),
            decisionHistory: decisionHistory,
            replacementHistory: replacementHistory,
            eventLog: eventLog,
            settings: settings,
            settingsWriter: hostCalls,
            presenter: hintPresenter.map(TypingHintPresenterAdapter.init(host:)) ?? NoOpAutoFixPresenter(),
            stats: hostCalls,
            wordList: hostCalls,
            undoShortcut: undoShortcut,
            logSubsystem: logSubsystem,
            tapThreadName: "\(logSubsystem).typing-tap"
        )
        applyHistorySettings()
        replacementHistory.bootstrap()
        decisionHistory.bootstrap()
    }

    /// Creates the key event tap. Returns false when the system refused it (a missing permission).
    /// Safe to call again later.
    @discardableResult
    public func start() -> Bool {
        isRunning = controller.start()
        return isRunning
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        controller.stop()
    }

    /// The host changed the focused text itself (for example, it pasted).
    public func noteExternalEdit() {
        controller.noteExternalEdit()
    }

    /// While paused every key passes through untouched and nothing is fixed.
    public func setPaused(_ paused: Bool) {
        controller.setPaused(paused)
    }

    public func undoLastFix() {
        controller.undoLastFix()
    }

    /// Selected text retyped in the next layout, as Papuga's manual switch does. The layout the text
    /// was typed in comes from the text itself. Nil when no other layout exists.
    public func layoutConversion(of text: String) -> TypingLayoutConversion? {
        let orderedIDs = layoutManager.orderedLayouts()
        for id in orderedIDs {
            if let source = layoutManager.sourceForID(id) { characterMapper.buildMap(for: source, sourceID: id) }
        }
        let sourceID = TextSwitchSourceLayout.sourceLayout(
            of: text,
            among: orderedIDs,
            systemLayoutID: layoutManager.getCurrentLayoutID()
        ) { character, id in
            self.characterMapper.mapping(for: character, sourceID: id) != nil
        }
        guard let targetID = layoutManager.nextLayout(after: sourceID, direction: .forward),
              targetID != sourceID,
              let source = layoutManager.sourceForID(sourceID),
              let target = layoutManager.sourceForID(targetID)
        else { return nil }
        characterMapper.buildMap(for: source, sourceID: sourceID)
        characterMapper.buildMap(for: target, sourceID: targetID)
        let converted = characterMapper.convert(text: text, fromSourceID: sourceID, toSourceID: targetID)
        return TypingLayoutConversion(original: text, converted: converted, sourceLayoutID: sourceID, targetLayoutID: targetID)
    }

    /// Call after the converted text was pasted: switches the system layout and records the switch.
    public func finishLayoutConversion(_ conversion: TypingLayoutConversion) {
        replacementHistory.record(ReplacementHistoryEntry(
            kind: .manualSwitch,
            original: conversion.original,
            converted: conversion.converted,
            sourceLayoutID: conversion.sourceLayoutID,
            targetLayoutID: conversion.targetLayoutID,
            bundleID: AppContextProvider.frontmostBundleID()
        ))
        hostCalls.recordReplacement(text: conversion.original)
        layoutManager.switchTo(conversion.targetLayoutID)
        controller.noteExternalEdit()
    }

    /// Call after `replacementHistoryEnabled` or `replacementHistoryRetention` changed.
    public func applyHistorySettings() {
        let current = settings()
        let retention = ReplacementHistoryRetention(rawValue: current.replacementHistoryRetention) ?? .oneMonth
        replacementHistory.isEnabled = current.replacementHistoryEnabled
        replacementHistory.retention = retention
        decisionHistory.isEnabled = current.replacementHistoryEnabled
        decisionHistory.retention = retention
    }
}

public struct TypingLayoutConversion: Equatable, Sendable {
    public let original: String
    public let converted: String
    public let sourceLayoutID: String
    public let targetLayoutID: String
}

/// Turns the controller's three host protocols into the optional closures of `TypingEngine.init`.
@MainActor
private final class HostCalls: TypingSettingsWriting, TypingStatsRecording, WordListEditing {
    private let onReplacementRecorded: ((String) -> Void)?
    private let onReplacementReversed: ((String) -> Void)?
    private let onCadenceGapWritten: ((Double) -> Void)?
    private let onRulesWritten: (([CustomAutoReplaceRule]) -> Void)?
    private let onWordAdded: ((String) -> Void)?
    private let onWordRemoved: ((String) -> Void)?

    init(
        onReplacementRecorded: ((String) -> Void)?,
        onReplacementReversed: ((String) -> Void)?,
        onCadenceGapWritten: ((Double) -> Void)?,
        onRulesWritten: (([CustomAutoReplaceRule]) -> Void)?,
        onWordAdded: ((String) -> Void)?,
        onWordRemoved: ((String) -> Void)?
    ) {
        self.onReplacementRecorded = onReplacementRecorded
        self.onReplacementReversed = onReplacementReversed
        self.onCadenceGapWritten = onCadenceGapWritten
        self.onRulesWritten = onRulesWritten
        self.onWordAdded = onWordAdded
        self.onWordRemoved = onWordRemoved
    }

    func setTypingCadenceAverageGap(_ gap: Double) { onCadenceGapWritten?(gap) }
    func setCustomAutoReplaceRules(_ rules: [CustomAutoReplaceRule]) { onRulesWritten?(rules) }
    func recordReplacement(text: String) { onReplacementRecorded?(text) }
    func reverseReplacement(text: String) { onReplacementReversed?(text) }
    func add(_ rawWord: String) { onWordAdded?(rawWord) }
    func remove(_ rawWord: String) { onWordRemoved?(rawWord) }
}
