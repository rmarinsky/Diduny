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

    /// True between a `start()` that returned true and the next `stop()`.
    public private(set) var isRunning = false

    /// - Parameters:
    ///   - storageDirectory: where the history and event files live. Created when missing.
    ///   - settings: read on the main actor every time the engine needs a setting, so keep it cheap.
    ///   - logSubsystem: the OSLog subsystem of the host.
    ///   - hintPresenter: shows the undo hint, the proposal, the recovery hint and the deferred chip.
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
        controller = AutoFixController(
            layoutManager: LayoutManager(layoutOrder: initial.layoutOrder, disabledLayouts: initial.disabledLayouts),
            characterMapper: CharacterMapper(),
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
