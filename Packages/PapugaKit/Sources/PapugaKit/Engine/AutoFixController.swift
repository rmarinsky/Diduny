import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

@MainActor
final class AutoFixController {
    private let layoutManager: LayoutManager
    private let characterMapper: CharacterMapper
    private let logger: Logger

    /// The event tap runs on its own high-priority thread (not the main run loop) so its callback
    /// is never starved by main-thread UI work — which would delay keystroke pass-through to the
    /// frontmost app and risk the window server disabling the tap (tapDisabledByTimeout).
    /// `let` so the nonisolated tap callback can reach it without an actor hop / data race.
    private let eventTapRunner: AutoFixEventTap

    private static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue) |
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue)

    private var buffer = WordBuffer()
    private var lastFix: PendingUndo?
    /// When the last automatic replacement landed, until the user types on.
    /// Deleting into it right away is a rejection nobody clicks Undo for.
    private var implicitUndoWatch: (appliedAt: TimeInterval, backspaces: Int, bundleID: String)?
    private var pendingProposalRecovery: PendingProposalRecovery?
    private var pendingReapply: PendingReapply?
    /// One slot, newest wins: the fix the user typed past, kept alive as a
    /// passive chip until they click it, close it, or it times out.
    private var pendingDeferredChip: AutoFixProposal?
    private var editingGuard = AutoFixEditingGuard()
    private var layoutIncident = LayoutIncidentTracker()
    private var layoutIncidentContext: LayoutIncidentContext?
    private var pendingSingleDecision: DeferredSingleDecision?
    private var isCapturingLayoutIncident = false
    /// Restored from the last session; falls back to the typing-test WPM, then
    /// to a middling default. Persisted in `stop()`.
    private var cadence: TypingCadenceTracker
    private var layoutIncidentTimerState = LayoutIncidentTimerState()
    private var layoutIncidentTimerTask: Task<Void, Never>?
    private let spellChecker: SpellCheckingClient
    private let decisionHistory: AutoFixDecisionRecording
    private var activeDecisionDraft: AutoFixDecisionDraft?
    private let manualCorrectionTracker = ManualCorrectionTracker()
    private let targetValidator = AutoFixTargetValidator()
    private var appActivationObserver: NSObjectProtocol?
    private var consecutiveReplacementDirection: AutoFixReplacementDirection?
    /// Cached language scorer, reused across word boundaries (rebuilt only if the algorithm
    /// changes). Avoids per-word scorer/NLLanguageRecognizer allocation. Safe: only touched on the
    /// main actor inside evaluateAndMaybeFix.
    private var cachedScorer: (algorithm: LanguageScorerAlgorithm, scorer: LanguageScorer)?
    /// Reused for synthetic delete/type keystroke bursts instead of allocating a CGEventSource per
    /// fix/undo. Only used on the main actor.
    /// Was a cached copy of the settings-backed rule list kept in sync through a settings
    /// observer. The host's settings provider is now the cache: this reads the current list.
    private var cachedCustomRules: [CustomAutoReplaceRule] { settings().customAutoReplaceRules }

    /// Read on the main actor at every point that used to read a Papuga setting.
    private let settings: @MainActor () -> TypingSettings
    private let settingsWriter: TypingSettingsWriting
    private let presenter: AutoFixPresenting
    private let replacementHistory: ReplacementHistoryStore
    private let eventLog: PapugaEventLog
    private let stats: TypingStatsRecording
    private let wordList: WordListEditing
    private let undoShortcut: @MainActor () -> AutoFixUndoShortcut?
    /// True while the focused field is a password field or secure input is on.
    private let isSecureField: @MainActor () -> Bool
    private let replacementNotificationName: Notification.Name
    /// Set by `setPaused(_:)`. While true the event tap is disabled, so no key reaches the controller.
    private(set) var isPaused = false

    init(
        layoutManager: LayoutManager,
        characterMapper: CharacterMapper,
        spellChecker: SpellCheckingClient,
        decisionHistory: AutoFixDecisionRecording,
        replacementHistory: ReplacementHistoryStore,
        eventLog: PapugaEventLog,
        settings: @escaping @MainActor () -> TypingSettings,
        settingsWriter: TypingSettingsWriting,
        presenter: AutoFixPresenting,
        stats: TypingStatsRecording,
        wordList: WordListEditing,
        undoShortcut: @escaping @MainActor () -> AutoFixUndoShortcut? = { nil },
        isSecureField: @escaping @MainActor () -> Bool = { ManualReplacementSnapshot.focusedFieldIsSecure() },
        logSubsystem: String = Constants.bundleIdentifier,
        tapThreadName: String = AutoFixEventTap.defaultThreadName,
        replacementNotificationName: Notification.Name = .textReplacementDidComplete
    ) {
        self.layoutManager = layoutManager
        self.characterMapper = characterMapper
        self.spellChecker = spellChecker
        self.decisionHistory = decisionHistory
        self.replacementHistory = replacementHistory
        self.eventLog = eventLog
        self.settings = settings
        self.settingsWriter = settingsWriter
        self.presenter = presenter
        self.stats = stats
        self.wordList = wordList
        self.undoShortcut = undoShortcut
        self.isSecureField = isSecureField
        self.replacementNotificationName = replacementNotificationName
        self.logger = Logger(subsystem: logSubsystem, category: "AutoFix")
        self.eventTapRunner = AutoFixEventTap(mask: AutoFixController.eventMask, threadName: tapThreadName)
        let initial = settings()
        self.cadence = TypingCadenceTracker(
            averageGap: initial.typingCadenceAverageGap > 0
                ? initial.typingCadenceAverageGap
                : TypingCadenceTracker.seededGap(wordsPerMinute: initial.measuredTypingWPM)
        )
    }

    /// Returns false when the event tap could not be created (for example, no Accessibility
    /// permission). Returns true when the tap is live, also when it was live already.
    @discardableResult
    func start() -> Bool {
        AppLogger.pre(logger, "AutoFixController.start()")
        guard !eventTapRunner.isActive else {
            AppLogger.warn(logger, "start() skipped: tap already active")
            return true
        }

        // Pass an unretained pointer to self; the controller outlives the tap (app lifetime) and
        // stop() tears the tap down before deinit.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard eventTapRunner.start(userInfo: userInfo, callback: autoFixCallback) else {
            AppLogger.error(logger, "CGEvent.tapCreate failed for AutoFixController")
            return false
        }

        isPaused = false
        installAppActivationObserverIfNeeded()
        AppLogger.post(logger, "AutoFixController tap attached (dedicated thread)")
        return true
    }

    func stop() {
        AppLogger.pre(logger, "AutoFixController.stop()")
        eventTapRunner.stop()
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        resetTypingState(clearLastFix: true)
        // A chip left on screen would still mutate text after AutoFix is off.
        dropDeferredChip(resolution: "chip_stopped")
        settingsWriter.setTypingCadenceAverageGap(cadence.averageGap)
        AppLogger.post(logger, "AutoFixController stopped")
    }

    /// Undo the most recent auto-fix on demand (e.g. from a global shortcut),
    /// if one is still pending. Restores the original word and layout.
    func undoLastFix() {
        guard let pending = lastFix else {
            AppLogger.post(logger, "undoLastFix() ignored: no pending fix")
            return
        }
        if let reapply = undo(pending) {
            showReapplyRecovery(reapply)
        }
        lastFix = nil
    }

    // MARK: - Host controls

    /// The host changed the focused text itself (for example, it pasted). Drops the typing
    /// buffer and the pending undo, the same reset a mouse click does.
    func noteExternalEdit() {
        resetTypingState(clearLastFix: true)
    }

    /// Pauses or resumes handling without tearing the tap down. While paused the tap is disabled,
    /// so every key passes through untouched. Both directions drop the typing buffer and the
    /// pending undo: keys typed across a pause must not join one word.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        resetTypingState(clearLastFix: true)
        eventTapRunner.setEnabled(!paused)
    }

    #if DEBUG
    var typingBufferForTesting: String { buffer.text }
    var hasPendingUndoForTesting: Bool { lastFix != nil }

    /// Feeds one key-down the way the tap does after its hop to the main thread.
    func processKeyDownForTesting(keyCode: UInt16, typedString: String, flags: CGEventFlags = []) {
        processEvent(
            type: .keyDown,
            targetPID: nil,
            keyCode: keyCode,
            flags: flags,
            typedString: typedString,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }
    #endif

    private func installAppActivationObserverIfNeeded() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // The chip's anchor belongs to the app the user just left.
                self?.dropDeferredChip(resolution: "chip_abandoned")
                self?.resetTypingState(clearLastFix: false)
            }
        }
    }

    private func resetTypingState(clearLastFix: Bool) {
        presenter.dismissProposal(outcome: nil)
        clearRecovery()
        buffer.reset()
        if clearLastFix {
            lastFix = nil
        }
        editingGuard.reset()
        resetLayoutIncident()
        manualCorrectionTracker.resetEditingState()
        targetValidator.reset()
        consecutiveReplacementDirection = nil
        // Whatever caused this reset (click, app switch, navigation) also broke
        // the typing rhythm — the next gap must not count toward the cadence.
        cadence.noteInterruption()
    }

    fileprivate nonisolated func handleEvent(type: CGEventType, event: CGEvent) {
        if PapugaSyntheticEvent.isTagged(event) {
            return
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Runs on the tap thread; re-enable directly (eventTapRunner is a thread-safe `let`).
            eventTapRunner.reEnable()
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let timestamp = ProcessInfo.processInfo.systemUptime
        let typedString = readTypedString(from: event)
        let targetPID = AutoFixTargetValidator.targetPID(from: event)

        DispatchQueue.main.async { [weak self] in
            self?.processEvent(
                type: type,
                targetPID: targetPID,
                keyCode: keyCode,
                flags: flags,
                typedString: typedString,
                timestamp: timestamp
            )
        }
    }

    fileprivate nonisolated func handleProposalShortcutSynchronously(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }

        // Fast path read directly on the tap thread — no main-thread hop. When no proposal is on
        // screen (the overwhelmingly common case) this returns immediately. The gate mirrors the
        // panel's visibility, set/cleared on the main actor in the coordinator's show/dismiss.
        guard AutoFixProposalShortcutGate.shared.isArmed else { return false }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Mirror the presenter's handleProposalKeyboardShortcut matching so we can decide to
        // swallow synchronously without blocking the tap thread on the main run loop.
        guard !flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else {
            return false
        }
        switch keyCode {
        case 0x24, 0x4C, 0x35: // Return, keypad Enter, Escape
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    _ = self?.presenter.handleProposalKeyboardShortcut(keyCode: keyCode, flags: flags)
                }
            }
            return true
        default:
            return false
        }
    }

    private nonisolated func readTypedString(from event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return "" }
        return AutoFixKeyEventText.sanitized(String(utf16CodeUnits: chars, count: length))
    }

    private func processEvent(
        type: CGEventType,
        targetPID: pid_t?,
        keyCode: UInt16,
        flags: CGEventFlags,
        typedString: String,
        timestamp: TimeInterval
    ) {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            // If the click is on our undo toast, let SwiftUI's Button handle it.
            // Resetting lastFix here would null out the pending undo before the
            // Button action can fire, defeating the toast.
            if presenter.isMouseOverToast()
                || presenter.isMouseOverChip()
                || presenter.isMouseOverProposal() {
                return
            }
            // A click elsewhere moves the caret and the user's attention — the
            // deferred fix is stale context now.
            dropDeferredChip(resolution: "chip_abandoned")
            resetTypingState(clearLastFix: true)
            // A click may land inside existing text, so suppress the very next word. We use
            // noteClickSuppression (not noteEditingStarted) so auto-fix resumes normally for every
            // word after that first one — typing a whole fresh word after clicking is safe.
            if settings().autoFixConservativeEditingGuard {
                editingGuard.noteClickSuppression()
            }
            return
        case .keyDown:
            break
        default:
            return
        }

        // Typing over a panel is not a rejection — the proposal demotes to the
        // deferred chip instead of dying (the coordinator no-ops when nothing
        // is on screen). Only printable text is typing over; arrows, Tab and
        // shortcuts just dismiss it.
        let typesText = AutoFixKeyEventText.typesOverProposal(typedString, flags: flags)
        presenter.dismissProposal(outcome: typesText ? .typedOver : .dismissed)
        clearRecovery()

        // Before every branch that resets typing state: `lastFix` has to survive until
        // the shortcut fires on keyUp.
        if isUndoShortcut(keyCode: keyCode, flags: flags) {
            return
        }

        let isBoundary = isWordBoundary(keyCode: keyCode, typedString: typedString)
        if type == .keyDown,
           !typedString.isEmpty,
           !isBoundary {
            cadence.notePrintable(at: timestamp)
            notePrintableContinuation(timestamp: timestamp)
        }

        if flags.contains(.maskCommand) {
            resetTypingState(clearLastFix: true)
            return
        }

        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            handleBackspace(timestamp: timestamp)
            return
        }

        if isResetKey(keyCode) {
            resetTypingState(clearLastFix: true)
            editingGuard.noteResetKey(keyCode, enabled: settings().autoFixConservativeEditingGuard)
            return
        }

        if isBoundary {
            evaluateAndMaybeFix(boundary: typedString)
            editingGuard.noteBoundary()
            buffer.reset()
            targetValidator.reset()
            return
        }

        if !typedString.isEmpty {
            implicitUndoWatch = nil
            if buffer.text.isEmpty, isSecureField() {
                resetTypingState(clearLastFix: false)
                return
            }
            if buffer.text.isEmpty {
                targetValidator.startSession(targetPID: targetPID, keyCode: keyCode, typedString: typedString)
            } else {
                let validation = targetValidator.validateKeyEventStillTargetsSession(targetPID: targetPID)
                if case .changed = validation {
                    logSkip(.targetChanged, word: buffer.text, bundleID: AppContextProvider.frontmostBundleID() ?? "")
                    resetTypingState(clearLastFix: false)
                    targetValidator.startSession(targetPID: targetPID, keyCode: keyCode, typedString: typedString)
                }
            }
            buffer.append(string: typedString, keyCode: keyCode)
        }
    }

    private func handleBackspace(timestamp: TimeInterval) {
        let bufferWasEmpty = buffer.text.isEmpty
        noteBackspaceAfterFix(bufferWasEmpty: bufferWasEmpty, timestamp: timestamp)
        // The tap observes Backspace after the target editor has already consumed it. Using that
        // key as an undo gesture would therefore delete the untouched Space/Return/Tab boundary
        // before Papuga can validate anything. Undo remains available through the range-safe chip.
        lastFix = nil
        manualCorrectionTracker.noteBackspace(bufferWasEmpty: bufferWasEmpty, timestamp: timestamp)
        editingGuard.noteBackspace(bufferWasEmpty: bufferWasEmpty, enabled: settings().autoFixConservativeEditingGuard)
        resetLayoutIncident()
        buffer.popLast()
        if buffer.text.isEmpty {
            targetValidator.reset()
        }
    }

    /// Two deletes straight into a fresh replacement, before anything else is
    /// typed, mean the user is taking it back by hand. Telemetry only: it is
    /// the false-fix signal the unused Undo button never produced.
    private func noteBackspaceAfterFix(bufferWasEmpty: Bool, timestamp: TimeInterval) {
        guard var watch = implicitUndoWatch else { return }
        guard bufferWasEmpty, AutoFixDecision.isImplicitUndoWindow(elapsed: timestamp - watch.appliedAt) else {
            implicitUndoWatch = nil
            return
        }
        watch.backspaces += 1
        guard watch.backspaces >= 2 else {
            implicitUndoWatch = watch
            return
        }
        implicitUndoWatch = nil
        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixRetypedAfterFix,
            frontmostBundleID: watch.bundleID,
            inputLayout: layoutManager.getCurrentLayoutID(),
            properties: ["time_to_delete_ms": .int(Int((timestamp - watch.appliedAt) * 1000))]
        ))
    }

    private func undoFromToast() {
        guard let pending = lastFix else { return }
        if let reapply = undo(pending) {
            showReapplyRecovery(reapply)
        }
        lastFix = nil
    }

    private func undo(_ pending: PendingUndo) -> PendingReapply? {
        let bundleID = AppContextProvider.frontmostBundleID() ?? ""
        guard let replacementResult = targetValidator.replaceAnchoredText(
            pending.replacementAnchor,
            with: pending.original
        ) else {
            recordMutationFailure(
                source: pending.replacement,
                candidate: pending.original,
                fromLayoutID: pending.targetLayoutID,
                targetLayoutID: pending.fromLayoutID,
                bundleID: bundleID,
                scope: pending.replacement.contains(where: \.isWhitespace) ? .phrase : .word
            )
            return nil
        }
        AppLogger.action(logger, "Undoing recent auto-fix: replacementLength=\(pending.replacement.count) originalLength=\(pending.original.count)")
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - pending.timestamp) * 1000)
        if pending.changesInputLayout {
            layoutManager.switchTo(pending.fromLayoutID)
        }
        stats.reverseReplacement(text: pending.replacement)
        stats.observe(.undone(original: pending.original, replacement: pending.replacement))

        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixUndone,
            frontmostBundleID: bundleID,
            inputLayout: layoutManager.getCurrentLayoutID(),
            properties: [
                "original_length": .int(pending.original.count),
                "time_to_undo_ms": .int(elapsedMs)
            ]
        ))

        replacementHistory.record(
            ReplacementHistoryEntry(
                kind: .autoFixUndone,
                original: pending.original,
                converted: pending.replacement,
                sourceLayoutID: pending.fromLayoutID,
                targetLayoutID: nil,
                bundleID: bundleID
            )
        )
        guard let restoredAnchor = replacementResult.recoveryAnchor else { return nil }
        return PendingReapply(
            original: pending.original,
            replacement: pending.replacement,
            fromLayoutID: pending.fromLayoutID,
            targetLayoutID: pending.targetLayoutID,
            changesInputLayout: pending.changesInputLayout,
            replacementAnchor: restoredAnchor,
            expiresAt: ProcessInfo.processInfo.systemUptime + 10
        )
    }

    private func resolvedScorer(for algorithm: LanguageScorerAlgorithm) -> LanguageScorer {
        if let cached = cachedScorer, cached.algorithm == algorithm {
            return cached.scorer
        }
        let scorer = LanguageScorerFactory.make(algorithm)
        cachedScorer = (algorithm, scorer)
        return scorer
    }

    private func evaluateAndMaybeFix(boundary: String) {
        let word = buffer.text
        guard !word.isEmpty else {
            // Boundary fired with nothing typed: the latch is cleared by noteBoundary in the caller.
            return
        }
        guard !isSecureField() else {
            buffer.reset()
            return
        }

        let bundleID = AppContextProvider.frontmostBundleID() ?? ""
        let currentID = layoutManager.getCurrentLayoutID()
        let currentLang = languageHintForLayoutID(currentID)
        let configuredAlgorithm = (
            LanguageScorerAlgorithm(rawValue: settings().autoFixAlgorithm) ?? .appleNL
        ).resolvedImplementation
        beginDecision(
            source: word,
            sourceLayoutID: currentID,
            sourceLanguage: currentLang,
            bundleID: bundleID,
            algorithm: configuredAlgorithm
        )
        defer { finishDecision() }
        let targetSession = targetValidator.session
        let targetValidation = targetValidator.validateCurrentTarget(
            expectedBundleID: bundleID,
            source: word,
            boundary: boundary
        )
        if case .changed(let reason) = targetValidation {
            var extra: [String: AnalyticsValue] = [
                "target_reason": .string(reason),
                "from_lang": .string(currentLang)
            ]
            for (key, value) in caretMismatchProperties() {
                extra[key] = value
            }
            if let detail = targetValidator.lastTargetMismatchDetail {
                extra["target_detail"] = .string(detail)
            }
            logSkip(.targetChanged, word: word, bundleID: bundleID, extra: extra)
            resetLayoutIncident()
            return
        }

        // Read while it is still true. Anything that defers — the single-word grace
        // timer, the sentence idle timer — applies its fix hundreds of milliseconds
        // from now, by which point the user has typed on and the live caret no longer
        // describes where this token ended.
        let boundaryCaret = targetValidator.currentCaretLocation()

        let appPolicy = AutoFixAppPolicyResolver.policy(for: bundleID, overrides: settings().autoFixAppPolicyOverrides)
        guard appPolicy != .disabled else {
            logSkip(.unsafeEditor, word: word, bundleID: bundleID, extra: [
                "app_policy": .string(appPolicy.rawValue)
            ])
            resetLayoutIncident()
            return
        }
        let canMutateDirectly = targetValidation.canMutate && appPolicy.allowsAutomaticMutation

        if let correction = manualCorrectionTracker.noteCompletedWord(
            word,
            language: currentLang,
            bundleID: bundleID.isEmpty ? nil : bundleID,
            timestamp: ProcessInfo.processInfo.systemUptime
           ) {
            // The user is fixing this text by hand — offering to fix it too
            // would race them. (Apply-time verification is the safety net; this
            // just removes the chip before they have to look at it.)
            if let chip = pendingDeferredChip,
               ManualCorrectionTracker.phrase(chip.original, containsToken: correction.source) {
                dropDeferredChip(resolution: "chip_self_corrected")
            }
        }

        // The guard protects against a word glued to pre-existing text after a
        // click ("к|" + "nj" → "кnj"). When the field itself proves the word
        // stands alone — empty field, start of it, or appended after whitespace
        // — the danger is absent and the word stays fixable. This was eating
        // the first word of every fresh chat message.
        if editingGuard.shouldSuppress(enabled: settings().autoFixConservativeEditingGuard),
           let guardReason = targetValidator.typedWordStandsAloneRejection(
               source: word, boundary: boundary.isEmpty ? " " : boundary
           ) {
            logSkip(.editingContext, word: word, bundleID: bundleID, extra: [
                "from_lang": .string(currentLang),
                "guard_reason": .string(guardReason)
            ])
            resetLayoutIncident()
            // Words the user curated (blocklist, allowlist, rules) keep their
            // meaning; anything else that is unmistakably wrong-layout still
            // earns the layout switch.
            if appPolicy.allowsAutomaticMutation,
               !settings().autoFixBlocklist.contains(bundleID),
               !AutoFixDecision.isInAllowlist(word, allowlist: settings().autoFixAllowlist),
               !cachedCustomRules.contains(where: { $0.matches(word) }),
               let best = evaluateWord(word, currentID: currentID, threshold: settings().autoFixThreshold,
                                       algorithm: configuredAlgorithm).replacement {
                switchLayoutWithoutReplacing(fromLayoutID: currentID, targetLayoutID: best.targetID,
                                             bundleID: bundleID, cause: "editing_context")
            }
            return
        }

        if settings().autoFixBlocklist.contains(bundleID) {
            logSkip(.blocklist, word: word, bundleID: bundleID)
            resetLayoutIncident()
            return
        }

        // An explicit “Never replace” choice must override every mutation source,
        // including an older custom rule for the same word.
        if AutoFixDecision.isInAllowlist(word, allowlist: settings().autoFixAllowlist) {
            logSkip(.allowlist, word: word, bundleID: bundleID)
            // The word itself stays untouched, but it *ends* the run rather than
            // destroying it — the words before it are still a mistake worth
            // judging. Throwing the run away here silently dropped everything
            // typed ahead of an allowlisted word.
            finalizeLayoutIncident(trigger: .midFlow, typedPastRun: true)
            return
        }

        if let rule = cachedCustomRules.first(where: { $0.matches(word) }) {
            resetLayoutIncident()
            if canMutateDirectly {
                applyCustomRule(
                    rule: rule,
                    original: word,
                    boundary: boundary,
                    bundleID: bundleID,
                    targetSession: targetSession
                )
            } else if appPolicy.allowsProposal {
                showRuleProposal(
                    rule: rule,
                    original: word,
                    boundary: boundary,
                    fromLayoutID: currentID,
                    bundleID: bundleID,
                    targetSession: targetSession
                )
            } else {
                logSkip(.unsafeEditor, word: word, bundleID: bundleID)
            }
            return
        }

        let algorithm = configuredAlgorithm
        let threshold = settings().autoFixThreshold
        let evaluation = evaluateWord(word, currentID: currentID, threshold: threshold, algorithm: algorithm)
        let scoreOriginal = evaluation.scoreOriginal
        updateDecisionCandidates(scoreOriginal: scoreOriginal, candidates: evaluation.candidates, threshold: threshold)
        if case .fixSpelling(let suggestion) = evaluation.disposition {
            // An ordinary word of the current language: it ends any layout run.
            resetLayoutIncident()
            applySpellingFix(original: word, suggestion: suggestion, boundary: boundary,
                             layoutID: currentID, language: currentLang, algorithm: algorithm,
                             bundleID: bundleID, targetSession: targetSession,
                             canMutateDirectly: canMutateDirectly, allowsProposal: appPolicy.allowsProposal)
            return
        }
        if case .keep(let reason) = evaluation.disposition {
            logSkip(reason, word: word, bundleID: bundleID, layoutID: currentID)
            resetLayoutIncident()
            if reason != .likelySpellingTypo { stats.observe(.typed(word: word, language: currentLang)) }
            return
        }
        guard let selection = evaluation.selection else {
            resetLayoutIncident()
            stats.observe(.typed(word: word, language: currentLang))
            return
        }

        let targetID = selection.best.targetID
        let targetLang = selection.best.targetLang
        let candidate = selection.best.candidate
        let scoreCandidate = selection.best.scoreCandidate
        let isAmbiguousTarget = selection.isAmbiguous
        selectDecisionCandidate(selection.best)

        if evaluation.disposition == .shortWord {
            logSkip(.tooShort, word: word, bundleID: bundleID, layoutID: currentID)
            _ = handleLayoutIncidentToken(
                original: word,
                candidate: candidate,
                boundary: boundary,
                fromLayoutID: currentID,
                targetLayoutID: targetID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                rawScoreCandidate: scoreCandidate,
                threshold: threshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canMutateDirectly: canMutateDirectly,
                allowsProposal: appPolicy.allowsProposal,
                targetSession: targetSession,
                evidence: .neutral,
                singleAction: .none,
                boundaryCaret: boundaryCaret
            )
            return
        }

        // Hard guard against false positives like `faster` -> `афіеук`. If the
        // original is a real word in the current layout's language, the user
        // intended to type it; never replace.
        let hasLexicalCore = !BufferedToken(rawText: word, keyCodes: []).core.isEmpty
        if evaluation.disposition == .sourceWord {
            logSkip(.originalIsRealWord, word: word, bundleID: bundleID, layoutID: currentID, extra: [
                "from_lang": .string(currentLang)
            ])
            _ = handleLayoutIncidentToken(
                original: word,
                candidate: candidate,
                boundary: boundary,
                fromLayoutID: currentID,
                targetLayoutID: targetID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                rawScoreCandidate: scoreCandidate,
                threshold: threshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canMutateDirectly: canMutateDirectly,
                allowsProposal: appPolicy.allowsProposal,
                targetSession: targetSession,
                evidence: AutoFixWordEvaluator.isAmbiguousShortSourceWord(
                    word, candidate: candidate, targetLanguage: targetLang, spellChecker: spellChecker
                ) ? .neutral : .contradiction,
                singleAction: .none,
                boundaryCaret: boundaryCaret
            )
            return
        }

        if evaluation.disposition == .suggestLayout {
            if appPolicy.allowsProposal {
                maybeShowProposal(original: word, candidate: candidate, boundary: boundary,
                    fromLayoutID: currentID, targetLayoutID: targetID,
                    scoreOriginal: scoreOriginal, scoreCandidate: scoreCandidate, threshold: threshold,
                    algorithm: algorithm, currentLang: currentLang, targetLang: targetLang,
                    bundleID: bundleID, targetSession: targetSession, force: true)
            }
            resetLayoutIncident()
            return
        }
        if case .suggestCompound(let suggestion) = evaluation.disposition {
            if appPolicy.allowsProposal, settings().autoFixProposalEnabled {
                showCompoundProposal(original: word, suggestion: suggestion, boundary: boundary,
                    fromLayoutID: currentID, targetLayoutID: targetID, currentLang: currentLang,
                    targetLang: targetLang, algorithm: algorithm, bundleID: bundleID,
                    targetSession: targetSession, scoreOriginal: scoreOriginal, threshold: threshold)
            }
            resetLayoutIncident()
            return
        }

        if case .suggestSpelling(let typoAssessment) = evaluation.disposition {
            if typoAssessment.shouldSuppressAutoReplace {
                var extra: [String: AnalyticsValue] = [
                    "candidate_length": .int(candidate.count),
                    "from_lang": .string(currentLang),
                    "to_lang": .string(targetLang)
                ]
                extra["has_spell_suggestion"] = .bool(typoAssessment.suggestion != nil)
                if let editDistance = typoAssessment.editDistance {
                    extra["edit_distance"] = .int(editDistance)
                }
                logSkip(.likelySpellingTypo, word: word, bundleID: bundleID, extra: extra)
                let interruptedIncident = isCapturingLayoutIncident || pendingSingleDecision != nil
                if interruptedIncident {
                    markDecisionAggregateOnly(matching: word)
                    resetLayoutIncident()
                    return
                }
                if let suggestion = typoAssessment.suggestion,
                   let editDistance = typoAssessment.editDistance {
                    let confidence = AutoFixDecision.spellingConfidence(
                        original: word, suggestion: suggestion, editDistance: editDistance
                    )
                    if appPolicy.allowsProposal, settings().autoFixProposalEnabled {
                        showSpellingProposal(
                            original: word,
                            suggestion: suggestion,
                            confidence: confidence,
                            boundary: boundary,
                            layoutID: currentID,
                            language: currentLang,
                            algorithm: algorithm,
                            bundleID: bundleID,
                            targetSession: targetSession
                        )
                    } else {
                        updateSpellingDecision(suggestion: suggestion, source: word, confidence: confidence)
                        markDecision(
                            outcome: .skipped,
                            reason: AutoFixSkipReason.likelySpellingTypo.rawValue,
                            signalKind: .spellingSuggestion,
                            candidateOrigin: .spelling,
                            matching: word
                        )
                    }
                } else {
                    markDecisionAggregateOnly(matching: word)
                }
                resetLayoutIncident()
                return
            }
        }

        let predictionAdjustment = ProtectedLexiconPredictionScorer.adjustment(
            original: word,
            candidate: candidate,
            scoreCandidate: scoreCandidate,
            threshold: threshold
        )
        let effectiveScoreCandidate = evaluation.effectiveScore
        let effectiveThreshold = evaluation.threshold
        updateEffectiveDecisionScore(
            effectiveCandidateScore: effectiveScoreCandidate,
            threshold: effectiveThreshold
        )

        AppLogger.post(
            logger,
            "Eval word=\(word) -> \(candidate); scores: \(scoreOriginal) vs \(effectiveScoreCandidate); threshold=\(effectiveThreshold)"
        )

        guard evaluation.disposition == .replace || selection.isAmbiguous else {
            var extra: [String: AnalyticsValue] = [
                "score_original": .double(scoreOriginal),
                "score_candidate": .double(effectiveScoreCandidate),
                "score_candidate_raw": .double(scoreCandidate),
                "algorithm": .string(algorithm.rawValue),
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang)
            ]
            if let candidateMatch = predictionAdjustment.candidateMatch {
                extra["lexicon_candidate_id"] = .string(candidateMatch.entry.id)
                extra["lexicon_reasons"] = .string(predictionAdjustment.reasons.joined(separator: ","))
            }
            logSkip(.belowThreshold, word: word, bundleID: bundleID, layoutID: currentID, extra: extra)
            let shouldOfferSingleProposal = appPolicy.allowsProposal && (
                AutoFixProposalPolicy.shouldSuggest(
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: effectiveScoreCandidate,
                    threshold: effectiveThreshold,
                    window: settings().autoFixProposalWindow
                ) || AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
                    original: word,
                    candidate: candidate,
                    targetLanguage: targetLang,
                    scoreCandidate: effectiveScoreCandidate
                )
            )
            if handleLayoutIncidentToken(
                original: word,
                candidate: candidate,
                boundary: boundary,
                fromLayoutID: currentID,
                targetLayoutID: targetID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: effectiveScoreCandidate,
                rawScoreCandidate: scoreCandidate,
                threshold: effectiveThreshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canMutateDirectly: canMutateDirectly,
                allowsProposal: appPolicy.allowsProposal,
                targetSession: targetSession,
                evidence: layoutIncidentEvidence(
                    original: word,
                    candidate: candidate,
                    sourceLanguage: currentLang,
                    targetLanguage: targetLang,
                    targetLayoutID: targetID,
                    candidateScore: effectiveScoreCandidate
                ),
                singleAction: shouldOfferSingleProposal ? .proposal(force: false) : .none,
                boundaryCaret: boundaryCaret
            ) {
                return
            }
            if appPolicy.allowsProposal {
                maybeShowProposal(
                    original: word,
                    candidate: candidate,
                    boundary: boundary,
                    fromLayoutID: currentID,
                    targetLayoutID: targetID,
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: effectiveScoreCandidate,
                    threshold: effectiveThreshold,
                    algorithm: algorithm,
                    currentLang: currentLang,
                    targetLang: targetLang,
                    bundleID: bundleID,
                    targetSession: targetSession
                )
            }
            return
        }

        let deferredAction: DeferredSingleAction
        if !hasLexicalCore {
            deferredAction = .none
        } else if !canMutateDirectly {
            deferredAction = appPolicy.allowsProposal ? .proposal(force: true) : .none
        } else if isAmbiguousTarget {
            deferredAction = appPolicy.allowsProposal ? .proposal(force: true) : .none
        } else {
            deferredAction = .replace
        }
        if handleLayoutIncidentToken(
            original: word,
            candidate: candidate,
            boundary: boundary,
            fromLayoutID: currentID,
            targetLayoutID: targetID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: effectiveScoreCandidate,
            rawScoreCandidate: scoreCandidate,
            hasVerifiedLayoutWord: evaluation.replacement != nil,
            threshold: effectiveThreshold,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            canMutateDirectly: canMutateDirectly,
            allowsProposal: appPolicy.allowsProposal,
            targetSession: targetSession,
            evidence: layoutIncidentEvidence(
                original: word,
                candidate: candidate,
                sourceLanguage: currentLang,
                targetLanguage: targetLang,
                targetLayoutID: targetID,
                candidateScore: effectiveScoreCandidate
            ),
            singleAction: deferredAction,
            boundaryCaret: boundaryCaret
        ) {
            return
        }

        guard canMutateDirectly else {
            if evaluation.replacement != nil, appPolicy.allowsAutomaticMutation {
                switchLayoutWithoutReplacing(fromLayoutID: currentID, targetLayoutID: targetID,
                                             bundleID: bundleID, cause: "target_unverifiable")
            }
            if appPolicy.allowsProposal {
                maybeShowProposal(
                    original: word,
                    candidate: candidate,
                    boundary: boundary,
                    fromLayoutID: currentID,
                    targetLayoutID: targetID,
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: effectiveScoreCandidate,
                    threshold: effectiveThreshold,
                    algorithm: algorithm,
                    currentLang: currentLang,
                    targetLang: targetLang,
                    bundleID: bundleID,
                    targetSession: targetSession,
                    force: true
                )
            } else {
                logSkip(.unsafeEditor, word: word, bundleID: bundleID, extra: [
                    "app_policy": .string(appPolicy.rawValue)
                ])
            }
            resetLayoutIncident()
            return
        }

        resetLayoutIncident()

        // Two plausible target layouts scored within the separation margin (e.g. Ukrainian vs
        // Russian on short Cyrillic text): don't guess a direction — surface a proposal instead.
        if isAmbiguousTarget {
            logSkip(.ambiguousTarget, word: word, bundleID: bundleID, layoutID: currentID, extra: [
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang),
                "runner_up_lang": .string(selection.runnerUp.map { languageHintForLayoutID($0.targetID) } ?? "")
            ])
            if appPolicy.allowsProposal {
                maybeShowProposal(
                    original: word,
                    candidate: candidate,
                    boundary: boundary,
                    fromLayoutID: currentID,
                    targetLayoutID: targetID,
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: effectiveScoreCandidate,
                    threshold: effectiveThreshold,
                    algorithm: algorithm,
                    currentLang: currentLang,
                    targetLang: targetLang,
                    bundleID: bundleID,
                    targetSession: targetSession,
                    force: true
                )
            }
            return
        }

        let didApply = applyFix(
            original: word,
            candidate: candidate,
            boundary: boundary,
            fromLayoutID: currentID,
            targetLayoutID: targetID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: effectiveScoreCandidate,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            targetSession: targetSession
        )
        if !didApply {
            switchLayoutWithoutReplacing(fromLayoutID: currentID, targetLayoutID: targetID,
                                         bundleID: bundleID, cause: "replacement_failed")
        }
    }

    private func evaluateWord(
        _ word: String,
        currentID: String,
        threshold: Double,
        algorithm: LanguageScorerAlgorithm
    ) -> AutoFixWordEvaluation {
        let evaluator = AutoFixWordEvaluator(mapper: characterMapper, spellChecker: spellChecker,
            scorer: resolvedScorer(for: algorithm))
        return evaluator.evaluate(word,
            source: layoutManager.availableLayouts.first { $0.id == currentID },
            targets: layoutManager.candidateTargets(excluding: currentID).compactMap { id in
                layoutManager.availableLayouts.first { $0.id == id }
            },
            configuration: .init(minimumLength: settings().autoFixMinWordLength, threshold: threshold,
                candidateSeparation: settings().autoFixCandidateSeparation,
                spellingTypoGuardEnabled: settings().autoFixSpellingTypoGuardEnabled,
                spellingTypoGuardMinimumLength: settings().autoFixSpellingTypoGuardMinWordLength,
                spellingTypoGuardMaximumDistance: settings().autoFixSpellingTypoGuardMaxEditDistance),
            previousWord: layoutIncident.tokens.last?.original)
    }

    /// The text could not be replaced safely, but the evidence that the layout
    /// is wrong stands on its own: switching now stops the mistake at this word
    /// instead of letting it run to the end of the sentence. What is already
    /// typed stays as it is — the manual hotkey converts it.
    private func switchLayoutWithoutReplacing(
        fromLayoutID: String,
        targetLayoutID: String,
        bundleID: String,
        cause: String
    ) {
        let policy = AutoFixLayoutSwitchPolicy(rawValue: settings().autoFixLayoutSwitchPolicy) ?? .adaptive
        guard policy != .keepCurrentLayout,
              fromLayoutID != targetLayoutID,
              layoutManager.getCurrentLayoutID() == fromLayoutID
        else { return }
        layoutManager.switchTo(targetLayoutID)
        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixLayoutOnly,
            frontmostBundleID: bundleID,
            inputLayout: targetLayoutID,
            properties: ["cause": .string(cause)]
        ))
    }

    private func layoutIncidentEvidence(
        original: String,
        candidate: String,
        sourceLanguage: String,
        targetLanguage: String,
        targetLayoutID: String,
        candidateScore: Double
    ) -> LayoutIncidentToken.Evidence {
        let assessment = PhraseLayoutPolicy.assess(
            originalCore: original,
            correctedCore: candidate,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            targetLayoutID: targetLayoutID,
            isAmbiguous: false,
            isKnownCorrect: { [spellChecker] word, language in
                !spellChecker.isMisspelled(word, language: language)
            }
        )
        if case .layoutCandidate = assessment {
            return .strong
        }
        if assessment == .keep {
            return .contradiction
        }
        if AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
            original: original,
            candidate: candidate,
            targetLanguage: targetLanguage,
            scoreCandidate: candidateScore
        ) {
            return .strong
        }
        return .neutral
    }

    @discardableResult
    private func handleLayoutIncidentToken(
        original: String,
        candidate: String,
        boundary: String,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        // The un-boosted language score. `scoreCandidate` may carry the
        // ProtectedLexicon adjustment, which says *which word* is meant — it is
        // not evidence about how safe it is to skip the grace period. Only the
        // instant-apply bypass reads this.
        rawScoreCandidate: Double,
        hasVerifiedLayoutWord: Bool = false,
        threshold: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        canMutateDirectly: Bool,
        allowsProposal: Bool,
        targetSession: AutoFixTargetSession?,
        evidence: LayoutIncidentToken.Evidence,
        singleAction: DeferredSingleAction,
        boundaryCaret: Int?
    ) -> Bool {
        let context = LayoutIncidentContext(
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            canMutateDirectly: canMutateDirectly,
            allowsProposal: allowsProposal,
            threshold: threshold,
            targetSession: targetSession
        )
        let token = LayoutIncidentToken(
            original: original,
            candidate: candidate,
            boundary: boundary.isEmpty ? " " : boundary,
            targetLayoutID: targetLayoutID,
            evidence: evidence,
            boundaryCaret: boundaryCaret
        )

        if isCapturingLayoutIncident {
            if let existing = layoutIncidentContext,
               !existing.matches(context) {
                resetLayoutIncident()
            } else {
                let result = layoutIncident.append(token)
                if result == .targetChanged {
                    resetLayoutIncident()
                } else if result == .wouldExceedCap {
                    let untouchedSuffix = layoutIncident.trailingBoundary
                        + original
                        + token.boundary
                    finalizeLayoutIncident(boundaryOverride: untouchedSuffix, trigger: .midFlow)
                    return handleLayoutIncidentToken(
                        original: original,
                        candidate: candidate,
                        boundary: boundary,
                        fromLayoutID: fromLayoutID,
                        targetLayoutID: targetLayoutID,
                        scoreOriginal: scoreOriginal,
                        scoreCandidate: scoreCandidate,
                        rawScoreCandidate: rawScoreCandidate,
                        hasVerifiedLayoutWord: hasVerifiedLayoutWord,
                        threshold: threshold,
                        algorithm: algorithm,
                        currentLang: currentLang,
                        targetLang: targetLang,
                        bundleID: bundleID,
                        canMutateDirectly: canMutateDirectly,
                        allowsProposal: allowsProposal,
                        targetSession: targetSession,
                        evidence: evidence,
                        singleAction: singleAction,
                        boundaryCaret: boundaryCaret
                    )
                } else if evidence == .contradiction {
                    markDecisionAggregateOnly(matching: original)
                    finalizeLayoutIncident(trigger: .midFlow)
                    return true
                } else if result == .reachedCap
                            || layoutIncident.endsSentence
                            || LayoutIncidentTracker.isHardBoundary(boundary) {
                    markDecisionAggregateOnly(matching: original)
                    finalizeLayoutIncident(trigger: .midFlow)
                    return true
                } else {
                    markDecisionAggregateOnly(matching: original)
                    armLayoutIncidentIdleTimer()
                    return true
                }
            }
        }

        if case .replace = singleAction,
           AutoFixDecision.shouldBypassLayoutIncidentGrace(scoreCandidate: rawScoreCandidate,
               hasVerifiedLayoutWord: hasVerifiedLayoutWord) {
            return false
        }

        guard evidence != .contradiction else { return false }

        // A weak word is only weak alone: "nj" scores nothing by itself, yet in
        // "nj ljhtxs" it is obviously "то". Runs used to open only on a strong
        // token, so weak words typed BEFORE the first strong one fell out of the
        // run forever — and the strong word then got replaced by itself, leaving
        // a half-converted phrase. A neutral token now opens the run too; the
        // joined run is judged as a whole at finalization.
        if evidence == .neutral {
            guard layoutIncident.append(token) != .wouldExceedCap else {
                resetLayoutIncident()
                return false
            }
            layoutIncidentContext = context
            isCapturingLayoutIncident = true
            markDecisionAggregateOnly(matching: original)
            if LayoutIncidentTracker.isHardBoundary(boundary) {
                finalizeLayoutIncident(trigger: .midFlow)
            } else {
                armLayoutIncidentIdleTimer()
            }
            return true
        }

        guard layoutIncident.append(token) != .wouldExceedCap else {
            resetLayoutIncident()
            return false
        }
        layoutIncidentContext = context
        pendingSingleDecision = DeferredSingleDecision(
            action: singleAction,
            original: original,
            candidate: candidate,
            boundary: token.boundary,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: threshold,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            targetSession: targetSession,
            boundaryCaret: boundaryCaret
        )
        markDecisionAggregateOnly(matching: original)
        if LayoutIncidentTracker.isHardBoundary(boundary) {
            executeDeferredSingleDecision()
            return true
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let grace = cadence.singleWordGrace
        layoutIncidentTimerState.armSingleWord(at: timestamp, grace: grace)
        scheduleLayoutIncidentTimer(after: grace)
        return true
    }

    private func notePrintableContinuation(timestamp: TimeInterval) {
        if layoutIncidentTimerState.consumeFastContinuation(at: timestamp),
           pendingSingleDecision != nil {
            layoutIncidentTimerTask?.cancel()
            layoutIncidentTimerTask = nil
            pendingSingleDecision = nil
            isCapturingLayoutIncident = true
            return
        }

        if isCapturingLayoutIncident {
            layoutIncidentTimerTask?.cancel()
            layoutIncidentTimerTask = nil
            layoutIncidentTimerState.reset()
        }
    }

    private func armLayoutIncidentIdleTimer() {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let idle = cadence.commitPause
        layoutIncidentTimerState.armIncidentIdle(at: timestamp, idle: idle)
        scheduleLayoutIncidentTimer(after: idle)
    }

    private func scheduleLayoutIncidentTimer(after delay: TimeInterval) {
        layoutIncidentTimerTask?.cancel()
        layoutIncidentTimerTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            self?.handleLayoutIncidentTimer(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func handleLayoutIncidentTimer(at timestamp: TimeInterval) {
        guard let action = layoutIncidentTimerState.takeDueAction(at: timestamp) else { return }
        layoutIncidentTimerTask = nil
        switch action {
        case .applySingleWord:
            executeDeferredSingleDecision()
        case .finalizeIncident:
            finalizeLayoutIncident()
        }
    }

    private func executeDeferredSingleDecision() {
        // Atomicity: a deferred single is only valid while the run it opened
        // still holds just that word. Once more tokens have joined, the run is
        // judged as a whole — a lone-word mutation inside a longer run is
        // exactly how phrases used to end up half-converted.
        guard layoutIncident.wordCount <= 1 else {
            pendingSingleDecision = nil
            finalizeLayoutIncident()
            return
        }
        guard let decision = pendingSingleDecision else {
            resetLayoutIncident()
            return
        }
        resetLayoutIncident()

        switch decision.action {
        case .none:
            return
        case .replace:
            let didApply = applyFix(
                original: decision.original,
                candidate: decision.candidate,
                boundary: decision.boundary,
                fromLayoutID: decision.fromLayoutID,
                targetLayoutID: decision.targetLayoutID,
                scoreOriginal: decision.scoreOriginal,
                scoreCandidate: decision.scoreCandidate,
                algorithm: decision.algorithm,
                currentLang: decision.currentLang,
                targetLang: decision.targetLang,
                bundleID: decision.bundleID,
                targetSession: decision.targetSession,
                boundaryCaret: decision.boundaryCaret
            )
            if !didApply {
                switchLayoutWithoutReplacing(fromLayoutID: decision.fromLayoutID,
                                             targetLayoutID: decision.targetLayoutID,
                                             bundleID: decision.bundleID, cause: "replacement_failed")
            }
            recordDeferredSingleDecision(
                decision,
                outcome: didApply ? .replaced : .skipped,
                reason: didApply ? nil : .targetUnverifiable,
                signalKind: didApply ? .replacement : .mutationFailure
            )
        case .proposal(let force):
            let didPresent = maybeShowProposal(
                original: decision.original,
                candidate: decision.candidate,
                boundary: decision.boundary,
                fromLayoutID: decision.fromLayoutID,
                targetLayoutID: decision.targetLayoutID,
                scoreOriginal: decision.scoreOriginal,
                scoreCandidate: decision.scoreCandidate,
                threshold: decision.threshold,
                algorithm: decision.algorithm,
                currentLang: decision.currentLang,
                targetLang: decision.targetLang,
                bundleID: decision.bundleID,
                targetSession: decision.targetSession,
                force: force,
                boundaryCaret: decision.boundaryCaret
            )
            if !didPresent {
                recordDeferredSingleDecision(
                    decision,
                    outcome: .skipped,
                    reason: .targetUnverifiable,
                    signalKind: .mutationFailure
                )
            }
        }
    }

    /// What caused the run to be judged. `.idle` — the user genuinely paused,
    /// so a panel in front of them is fine. `.midFlow` — a boundary keystroke
    /// (sentence end, Enter, cap, a correct word) closed the run while they
    /// were still typing; anything interactive would die under the next
    /// keystroke, so proposals surface as the passive chip instead.
    private enum LayoutIncidentFinalizeTrigger {
        case idle
        case midFlow
    }

    private func finalizeLayoutIncident(
        boundaryOverride: String? = nil,
        trigger: LayoutIncidentFinalizeTrigger = .idle,
        typedPastRun: Bool = false
    ) {
        guard let context = layoutIncidentContext,
              !layoutIncident.isEmpty else {
            resetLayoutIncident()
            return
        }
        let incident = layoutIncident
        resetLayoutIncident()

        // Judge and replace only the tokens that are part of the mistake — a
        // trailing contradiction (the correct word that ended the run) stays
        // untouched in the document.
        let judged = incident.judgedTokens
        guard !judged.isEmpty, let lastJudged = judged.last else { return }
        let trimmedTrailing = judged.count != incident.tokens.count

        let original = LayoutIncidentTracker.joinedBody(of: judged, \.original)
        let candidate = LayoutIncidentTracker.joinedBody(of: judged, \.candidate)
        // Per-token capture: the anchor belongs to the boundary of the last
        // *judged* token, sampled while it was still the live caret.
        let incidentBoundaryCaret = lastJudged.boundaryCaret
        // boundaryOverride describes text sitting after the FULL run (cap
        // overflow) and only serves the caret-less value-suffix match. A recorded
        // caret sits right after the last judged token's own boundary, so the
        // boundary must describe that same text or the computed range is shifted.
        let untouchedBoundary = trimmedTrailing || incidentBoundaryCaret != nil
            ? lastJudged.boundary
            : (boundaryOverride ?? incident.trailingBoundary)
        let allowsBlindReplacement = LayoutIncidentTracker.allowsBlindReplacement(
            typedPastRun: typedPastRun || trimmedTrailing || boundaryOverride != nil,
            boundaryCaret: incidentBoundaryCaret
        )
        let scorer = resolvedScorer(for: context.algorithm)
        let scoreOriginal = scorer.score(original, expecting: context.currentLang)
        let scoreCandidate = scorer.score(candidate, expecting: context.targetLang)
        let decision = LayoutIncidentTracker.runVerdict(
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: context.threshold,
            proposalWindow: settings().autoFixProposalWindow,
            hasContradiction: judged.contains { $0.evidence == .contradiction },
            hasUnanimousDictionarySupport: judged.allSatisfy { $0.evidence == .strong },
            hasStrongEvidence: judged.contains { $0.evidence == .strong },
            isDictionaryBackedRun: LayoutIncidentTracker.isDictionaryBackedRun(judged)
        )

        guard decision != .discard,
              !AutoFixDecision.shouldSuppressPhraseAutoReplace(
                original: original,
                candidate: candidate,
                sourceLanguage: context.currentLang,
                targetLanguage: context.targetLang,
                allowlist: settings().autoFixAllowlist
              ) else {
            // Discards used to vanish without a trace — the field data that
            // exposed the quorum bug had to be reconstructed by hand. Aggregate
            // counts are enough to see the miss rate.
            recordPhraseDecision(
                original: original,
                candidate: candidate,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: context.threshold,
                algorithm: context.algorithm,
                currentLang: context.currentLang,
                targetLang: context.targetLang,
                fromLayoutID: context.fromLayoutID,
                targetLayoutID: context.targetLayoutID,
                bundleID: context.bundleID,
                outcome: .skipped,
                reason: .belowThreshold,
                signalKind: nil
            )
            return
        }

        if decision == .replace, context.canMutateDirectly {
            let didApply = applyPhraseFix(
                original: original,
                candidate: candidate,
                boundary: untouchedBoundary,
                fromLayoutID: context.fromLayoutID,
                targetLayoutID: context.targetLayoutID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                algorithm: context.algorithm,
                currentLang: context.currentLang,
                targetLang: context.targetLang,
                bundleID: context.bundleID,
                targetSession: context.targetSession,
                boundaryCaret: incidentBoundaryCaret,
                allowsKeyboardFallback: allowsBlindReplacement
            )
            if !didApply {
                switchLayoutWithoutReplacing(fromLayoutID: context.fromLayoutID,
                                             targetLayoutID: context.targetLayoutID,
                                             bundleID: context.bundleID, cause: "replacement_failed")
            }
            recordPhraseDecision(
                original: original,
                candidate: candidate,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: context.threshold,
                algorithm: context.algorithm,
                currentLang: context.currentLang,
                targetLang: context.targetLang,
                fromLayoutID: context.fromLayoutID,
                targetLayoutID: context.targetLayoutID,
                bundleID: context.bundleID,
                outcome: didApply ? .replaced : .skipped,
                reason: didApply ? nil : .targetUnverifiable,
                signalKind: didApply ? .layoutIncident : .mutationFailure
            )
            return
        }

        if decision == .replace {
            switchLayoutWithoutReplacing(fromLayoutID: context.fromLayoutID,
                                         targetLayoutID: context.targetLayoutID,
                                         bundleID: context.bundleID, cause: "target_unverifiable")
        }

        guard context.allowsProposal, settings().autoFixProposalEnabled else {
            recordPhraseDecision(
                original: original,
                candidate: candidate,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: context.threshold,
                algorithm: context.algorithm,
                currentLang: context.currentLang,
                targetLang: context.targetLang,
                fromLayoutID: context.fromLayoutID,
                targetLayoutID: context.targetLayoutID,
                bundleID: context.bundleID,
                outcome: .skipped,
                reason: context.canMutateDirectly ? .belowThreshold : .unsafeEditor,
                signalKind: .layoutIncident
            )
            return
        }

        let didPresent = maybeShowProposal(
            original: original,
            candidate: candidate,
            boundary: untouchedBoundary,
            fromLayoutID: context.fromLayoutID,
            targetLayoutID: context.targetLayoutID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: context.threshold,
            algorithm: context.algorithm,
            currentLang: context.currentLang,
            targetLang: context.targetLang,
            bundleID: context.bundleID,
            targetSession: context.targetSession,
            force: true,
            boundaryCaret: incidentBoundaryCaret,
            presentation: trigger == .midFlow ? .chip : .panel
        )
        if !didPresent {
            recordPhraseDecision(
                original: original,
                candidate: candidate,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: context.threshold,
                algorithm: context.algorithm,
                currentLang: context.currentLang,
                targetLang: context.targetLang,
                fromLayoutID: context.fromLayoutID,
                targetLayoutID: context.targetLayoutID,
                bundleID: context.bundleID,
                outcome: .skipped,
                reason: .targetUnverifiable,
                signalKind: .mutationFailure
            )
        }
    }

    private func resetLayoutIncident() {
        layoutIncidentTimerTask?.cancel()
        layoutIncidentTimerTask = nil
        layoutIncidentTimerState.reset()
        layoutIncident.reset()
        layoutIncidentContext = nil
        pendingSingleDecision = nil
        isCapturingLayoutIncident = false
    }

    @discardableResult
    private func applyPhraseFix(
        original: String,
        candidate: String,
        boundary: String,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?,
        boundaryCaret: Int? = nil,
        allowsKeyboardFallback: Bool = true
    ) -> Bool {
        guard let replacementResult = performAnchoredReplacement(
            original: original,
            candidate: candidate,
            boundary: boundary,
            bundleID: bundleID,
            targetSession: targetSession,
            boundaryCaret: boundaryCaret,
            allowsKeyboardFallback: allowsKeyboardFallback
        ) else {
            return false
        }
        AppLogger.action(logger, "Auto-fix phrase applying: originalLength=\(original.count) candidateLength=\(candidate.count)")
        presenter.dismissProposal(outcome: nil)
        switchLayoutIfNeeded(
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scope: .phrase
        )

        let canUndo = setPendingUndo(
            original: original,
            replacement: candidate,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            recoveryAnchor: replacementResult.recoveryAnchor
        )

        stats.recordReplacement(text: candidate)
        NotificationCenter.default.post(name: replacementNotificationName, object: nil)

        showReplacementFeedback(canUndo: canUndo)

        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: bundleID,
            inputLayout: targetLayoutID,
            properties: [
                "original_length": .int(original.count),
                "replacement_length": .int(candidate.count),
                "score_original": .double(scoreOriginal),
                "score_candidate": .double(scoreCandidate),
                "algorithm": .string(algorithm.rawValue),
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang),
                "source": .string("phrase_auto_fix")
            ]
        ))

        replacementHistory.record(
            ReplacementHistoryEntry(
                kind: .autoFixApplied,
                original: original,
                converted: candidate,
                sourceLayoutID: fromLayoutID,
                targetLayoutID: targetLayoutID,
                bundleID: bundleID
            )
        )
        return true
    }

    @discardableResult
    private func applyFix(
        original: String,
        candidate: String,
        boundary: String,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?,
        boundaryCaret: Int? = nil
    ) -> Bool {
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let replacementResult = performAnchoredReplacement(
            original: original,
            candidate: candidate,
            boundary: boundaryToPreserve,
            bundleID: bundleID,
            targetSession: targetSession,
            boundaryCaret: boundaryCaret
        ) else {
            return false
        }
        AppLogger.action(logger, "Auto-fix applying: originalLength=\(original.count) candidateLength=\(candidate.count)")
        markDecision(outcome: .replaced, reason: nil, matching: original)
        switchLayoutIfNeeded(
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scope: .singleToken
        )

        let canUndo = setPendingUndo(
            original: original,
            replacement: candidate,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            recoveryAnchor: replacementResult.recoveryAnchor
        )

        stats.recordReplacement(text: candidate)
        NotificationCenter.default.post(name: replacementNotificationName, object: nil)

        showReplacementFeedback(canUndo: canUndo)

        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: bundleID,
            inputLayout: targetLayoutID,
            properties: [
                "original_length": .int(original.count),
                "replacement_length": .int(candidate.count),
                "score_original": .double(scoreOriginal),
                "score_candidate": .double(scoreCandidate),
                "algorithm": .string(algorithm.rawValue),
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang),
                "source": .string("auto_fix")
            ]
        ))

        replacementHistory.record(
            ReplacementHistoryEntry(
                kind: .autoFixApplied,
                original: original,
                converted: candidate,
                sourceLayoutID: fromLayoutID,
                targetLayoutID: targetLayoutID,
                bundleID: bundleID
            )
        )
        return true
    }

    /// How a proposal reaches the user: the interactive panel (they paused) or
    /// the passive deferred chip (they are still typing).
    private enum ProposalPresentation {
        case panel
        case chip
    }

    @discardableResult
    private func maybeShowProposal(
        original: String,
        candidate: String,
        boundary: String,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?,
        force: Bool = false,
        boundaryCaret: Int? = nil,
        presentation: ProposalPresentation = .panel
    ) -> Bool {
        guard settings().autoFixProposalEnabled else { return false }
        if !force {
            let shouldSuggestNearThreshold = AutoFixProposalPolicy.shouldSuggest(
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: threshold,
                window: settings().autoFixProposalWindow
            )
            let shouldSuggestLayoutMistake = AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
                original: original,
                candidate: candidate,
                targetLanguage: targetLang,
                scoreCandidate: scoreCandidate
            )
            guard shouldSuggestNearThreshold || shouldSuggestLayoutMistake else { return false }
        }

        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let targetSession,
              let replacementAnchor = targetValidator.captureReplacementAnchor(
                for: targetSession,
                expectedBundleID: bundleID,
                source: original,
                boundary: boundaryToPreserve,
                boundaryCaret: boundaryCaret
              )
        else {
            logTargetUnverifiable(word: original, bundleID: bundleID)
            return false
        }
        let proposal = AutoFixProposal(
            original: original,
            candidate: candidate,
            boundary: boundaryToPreserve,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: threshold,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            createdAt: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: replacementAnchor,
            kind: .detected
        )
        recordProposalPresentation(proposal)
        markDecision(
            outcome: .proposed,
            reason: nil,
            signalKind: original.contains(where: \.isWhitespace) ? .layoutIncident : .proposal,
            candidateOrigin: .keyboardLayout,
            matching: original
        )
        switch presentation {
        case .panel:
            presentProposal(proposal, recordDecision: false)
        case .chip:
            demoteProposalToChip(proposal)
        }
        return true
    }

    /// Applies a `NarrowTypoCorrector` fix in place, with the usual Undo. Where
    /// the editor cannot be mutated directly it degrades to the proposal.
    private func applySpellingFix(
        original: String,
        suggestion: String,
        boundary: String,
        layoutID: String,
        language: String,
        algorithm: LanguageScorerAlgorithm,
        bundleID: String,
        targetSession: AutoFixTargetSession?,
        canMutateDirectly: Bool,
        allowsProposal: Bool
    ) {
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard canMutateDirectly,
              let targetSession,
              let replacementAnchor = targetValidator.captureReplacementAnchor(
                for: targetSession,
                expectedBundleID: bundleID,
                source: original,
                boundary: boundaryToPreserve,
                allowsKeyboardFallback: false
              )
        else {
            if allowsProposal {
                showSpellingProposal(original: original, suggestion: suggestion, confidence: 1,
                                     boundary: boundary, layoutID: layoutID, language: language,
                                     algorithm: algorithm, bundleID: bundleID, targetSession: targetSession)
            }
            return
        }
        updateSpellingDecision(suggestion: suggestion, source: original, confidence: 1)
        let applied = applyProposal(AutoFixProposal(
            original: original,
            candidate: suggestion,
            boundary: boundaryToPreserve,
            fromLayoutID: layoutID,
            targetLayoutID: layoutID,
            scoreOriginal: 0,
            scoreCandidate: 1,
            threshold: 0,
            algorithm: algorithm,
            currentLang: language,
            targetLang: language,
            bundleID: bundleID,
            createdAt: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: replacementAnchor,
            kind: .spelling
        ), source: "spelling_auto")
        if applied {
            markDecision(outcome: .replaced, reason: nil, signalKind: .spellingSuggestion,
                         candidateOrigin: .spelling, matching: original)
        }
    }

    private func showSpellingProposal(
        original: String,
        suggestion: String,
        confidence: Double,
        boundary: String,
        layoutID: String,
        language: String,
        algorithm: LanguageScorerAlgorithm,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        guard settings().autoFixProposalEnabled else { return }
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let targetSession,
              let replacementAnchor = targetValidator.captureReplacementAnchor(
                for: targetSession,
                expectedBundleID: bundleID,
                source: original,
                boundary: boundaryToPreserve
              )
        else {
            logTargetUnverifiable(word: original, bundleID: bundleID)
            return
        }

        updateSpellingDecision(suggestion: suggestion, source: original, confidence: confidence)
        markDecision(
            outcome: .proposed,
            reason: AutoFixSkipReason.likelySpellingTypo.rawValue,
            signalKind: .spellingSuggestion,
            candidateOrigin: .spelling,
            matching: original
        )
        presentProposal(AutoFixProposal(
            original: original,
            candidate: suggestion,
            boundary: boundaryToPreserve,
            fromLayoutID: layoutID,
            targetLayoutID: layoutID,
            scoreOriginal: 0,
            scoreCandidate: 1,
            threshold: 0,
            algorithm: algorithm,
            currentLang: language,
            targetLang: language,
            bundleID: bundleID,
            createdAt: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: replacementAnchor,
            kind: .spelling
        ))
    }

    private func showCompoundProposal(
        original: String,
        suggestion: String,
        boundary: String,
        fromLayoutID: String,
        targetLayoutID: String,
        currentLang: String,
        targetLang: String,
        algorithm: LanguageScorerAlgorithm,
        bundleID: String,
        targetSession: AutoFixTargetSession?,
        scoreOriginal: Double,
        threshold: Double
    ) {
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let targetSession,
              let replacementAnchor = targetValidator.captureReplacementAnchor(
                for: targetSession,
                expectedBundleID: bundleID,
                source: original,
                boundary: boundaryToPreserve
              ) else { return }
        // Compound proposals used to be the one producer that recorded no
        // decision at all — invisible in history and aggregates alike.
        markDecision(
            outcome: .proposed,
            reason: nil,
            signalKind: .proposal,
            candidateOrigin: .keyboardLayout,
            matching: original
        )
        presentProposal(AutoFixProposal(
            original: original,
            candidate: suggestion,
            boundary: boundaryToPreserve,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: 0.74,
            threshold: threshold,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            createdAt: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: replacementAnchor,
            kind: .compound
        ))
    }

    private func showRuleProposal(
        rule: CustomAutoReplaceRule,
        original: String,
        boundary: String,
        fromLayoutID: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let targetSession,
              let replacementAnchor = targetValidator.captureReplacementAnchor(
                for: targetSession,
                expectedBundleID: bundleID,
                source: original,
                boundary: boundaryToPreserve
              )
        else {
            logTargetUnverifiable(word: original, bundleID: bundleID)
            return
        }
        let proposal = AutoFixProposal(
            original: original,
            candidate: rule.target,
            boundary: boundaryToPreserve,
            fromLayoutID: fromLayoutID,
            targetLayoutID: fromLayoutID,
            scoreOriginal: 0,
            scoreCandidate: 1,
            threshold: 0,
            algorithm: .appleNL,
            currentLang: languageHintForLayoutID(fromLayoutID),
            targetLang: languageHintForLayoutID(fromLayoutID),
            bundleID: bundleID,
            createdAt: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: replacementAnchor,
            kind: .customRule
        )
        updateCustomRuleDecision(candidate: rule.target, source: original)
        markDecision(outcome: .proposed, reason: nil, matching: original)
        presentProposal(proposal)
    }

    /// Records the presentation contract without touching windows or input.
    func recordProposalPresentation(_ proposal: AutoFixProposal) {
        // A presentation is the final decision for this token. Do not also flush
        // its draft, which may still contain an intermediate compound candidate.
        if activeDecisionDraft?.source == proposal.original { activeDecisionDraft = nil }
        decisionHistory.record(proposal.decisionObservation(
            proposalWindow: settings().autoFixProposalWindow,
            candidateSeparation: settings().autoFixCandidateSeparation,
            minimumWordLength: settings().autoFixMinWordLength))
    }

    private func presentProposal(_ proposal: AutoFixProposal, recordDecision: Bool = true) {
        if recordDecision { recordProposalPresentation(proposal) }
        presenter.showProposal(
            proposal: proposal,
            near: NSEvent.mouseLocation,
            duration: cadence.proposalDuration,
            actions: AutoFixProposalActions(
                replace: { [weak self] in
                    guard let self else { return }
                    let applied = self.acceptProposal(proposal)
                    self.logProposalResolution(proposal, resolution: applied ? "accepted" : "accept_failed")
                },
                dismiss: { [weak self] in
                    self?.logProposalResolution(proposal, resolution: "esc")
                    self?.showProposalRecovery(proposal)
                },
                typedOver: { [weak self] in
                    self?.logProposalResolution(proposal, resolution: "typed_over")
                    self?.demoteProposalToChip(proposal)
                },
                timedOut: { [weak self] in
                    self?.logProposalResolution(proposal, resolution: "timed_out")
                    self?.showProposalRecovery(proposal)
                },
                neverReplace: { [weak self] in
                    self?.logProposalResolution(proposal, resolution: "never_replace")
                    self?.neverReplace(proposal)
                }
            )
        )
    }

    // MARK: - Deferred chip

    /// Where the panel's death used to be the end of the road, the fix now
    /// waits — passive, keyboard-transparent — for the user to reach a natural
    /// stop and either click it in or let it fade.
    private func demoteProposalToChip(_ proposal: AutoFixProposal) {
        if let previous = pendingDeferredChip {
            logProposalResolution(previous, resolution: "chip_superseded")
        }
        pendingDeferredChip = proposal
        presenter.showDeferredChip(
            original: proposal.original,
            candidate: proposal.candidate,
            near: NSEvent.mouseLocation,
            timeToLive: cadence.chipTimeToLive,
            onApply: { [weak self] in
                self?.applyDeferredChip()
            },
            onDismiss: { [weak self] in
                self?.dropDeferredChip(resolution: "chip_dismissed")
            },
            onExpire: { [weak self] in
                self?.dropDeferredChip(resolution: "chip_expired")
            }
        )
    }

    private func applyDeferredChip() {
        guard let chip = pendingDeferredChip else { return }
        pendingDeferredChip = nil

        // The captured anchor survives text typed *after* it — the readback at
        // its exact range still proves it. Only when the anchor is dead (the
        // text shifted or the element re-created) fall back to locating the run
        // by content in the current field.
        // A chip exists because the user typed over the proposal, so a blind
        // keyboard-fallback anchor is never safe here; re-locate by content instead.
        if chip.replacementAnchor.survivesLaterTyping,
           targetValidator.isReplacementAnchorValid(chip.replacementAnchor) {
            logProposalResolution(chip, resolution: acceptProposal(chip) ? "chip_applied" : "chip_apply_failed")
            return
        }
        guard let anchor = targetValidator.captureRetroactiveAnchor(
            expectedBundleID: chip.bundleID,
            expectedIdentity: chip.replacementAnchor.focusedElementIdentity,
            source: chip.original,
            boundary: chip.boundary
        ) else {
            // The run is no longer (uniquely) in the field: sent, self-corrected,
            // or duplicated. Walk away without touching anything.
            logProposalResolution(chip, resolution: "chip_apply_failed")
            return
        }
        let reanchored = AutoFixProposal(
            original: chip.original,
            candidate: chip.candidate,
            boundary: chip.boundary,
            fromLayoutID: chip.fromLayoutID,
            targetLayoutID: chip.targetLayoutID,
            scoreOriginal: chip.scoreOriginal,
            scoreCandidate: chip.scoreCandidate,
            threshold: chip.threshold,
            algorithm: chip.algorithm,
            currentLang: chip.currentLang,
            targetLang: chip.targetLang,
            bundleID: chip.bundleID,
            createdAt: chip.createdAt,
            replacementAnchor: anchor,
            kind: chip.kind
        )
        logProposalResolution(chip, resolution: acceptProposal(reanchored) ? "chip_applied" : "chip_apply_failed")
    }

    private func dropDeferredChip(resolution: String) {
        guard let chip = pendingDeferredChip else { return }
        pendingDeferredChip = nil
        presenter.dismissChip()
        logProposalResolution(chip, resolution: resolution)
    }

    /// What actually became of a shown proposal. `.proposed` in the decision
    /// history is terminal, so without this the acceptance rate of the panel —
    /// the number every timing decision here should be tuned against — was
    /// unknowable.
    private func logProposalResolution(_ proposal: AutoFixProposal, resolution: String) {
        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixProposalResolved,
            frontmostBundleID: proposal.bundleID,
            inputLayout: proposal.fromLayoutID,
            properties: [
                "proposal_id": .string(proposal.id.uuidString),
                "proposal_kind": .string(String(describing: proposal.kind)),
                "resolution": .string(resolution),
                "original_length": .int(proposal.original.count),
                "age_ms": .int(Int((ProcessInfo.processInfo.systemUptime - proposal.createdAt) * 1000))
            ]
        ))
    }

    @discardableResult
    private func acceptProposal(_ proposal: AutoFixProposal) -> Bool {
        switch proposal.kind {
        case .detected:
            let canCreateRule = canCreateRule(from: proposal)
            let historyKind: ReplacementHistoryEntry.Kind = canCreateRule ? .autoRuleApplied : .autoFixApplied
            let applied = applyProposal(
                proposal,
                source: canCreateRule ? "proposal_auto_rule" : "proposal",
                historyKind: historyKind
            )
            if applied, canCreateRule {
                createRuleFromProposal(proposal)
            }
            return applied
        case .customRule:
            return applyProposal(proposal, source: "custom_rule_proposal", historyKind: .autoRuleApplied)
        case .spelling, .compound:
            return applyProposal(proposal, source: "spelling_proposal", historyKind: .autoFixApplied)
        }
    }

    @discardableResult
    private func applyProposal(
        _ proposal: AutoFixProposal,
        source: String,
        historyKind: ReplacementHistoryEntry.Kind = .autoFixApplied
    ) -> Bool {
        guard let replacementResult = targetValidator.replaceAnchoredText(
            proposal.replacementAnchor,
            with: proposal.candidate
        ) else {
            recordMutationFailure(
                source: proposal.original,
                candidate: proposal.candidate,
                fromLayoutID: proposal.fromLayoutID,
                targetLayoutID: proposal.targetLayoutID,
                bundleID: proposal.bundleID,
                scope: proposal.original.contains(where: \.isWhitespace) ? .phrase : .word,
                algorithm: proposal.algorithm,
                sourceLanguage: proposal.currentLang,
                targetLanguage: proposal.targetLang,
                candidateOrigin: proposal.candidateOrigin
            )
            return false
        }
        AppLogger.action(logger, "AutoFix proposal accepted: originalLength=\(proposal.original.count) candidateLength=\(proposal.candidate.count)")
        resetLayoutIncident()
        let replacementScope: ReplacementScope = proposal.original.contains(where: \.isWhitespace) ? .phrase : .singleToken
        if proposal.changesInputLayout {
            switchLayoutIfNeeded(
                fromLayoutID: proposal.fromLayoutID,
                targetLayoutID: proposal.targetLayoutID,
                scope: replacementScope
            )
        }

        let canUndo = setPendingUndo(
            original: proposal.original,
            replacement: proposal.candidate,
            fromLayoutID: proposal.fromLayoutID,
            targetLayoutID: proposal.targetLayoutID,
            changesInputLayout: proposal.changesInputLayout,
            recoveryAnchor: replacementResult.recoveryAnchor
        )

        stats.recordReplacement(text: proposal.candidate)
        NotificationCenter.default.post(name: replacementNotificationName, object: nil)

        showReplacementFeedback(canUndo: canUndo)

        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: proposal.bundleID,
            inputLayout: proposal.targetLayoutID,
            properties: [
                "proposal_id": .string(proposal.id.uuidString),
                "original_length": .int(proposal.original.count),
                "replacement_length": .int(proposal.candidate.count),
                "score_original": .double(proposal.scoreOriginal),
                "score_candidate": .double(proposal.scoreCandidate),
                "algorithm": .string(proposal.algorithm.rawValue),
                "from_lang": .string(proposal.currentLang),
                "to_lang": .string(proposal.targetLang),
                "source": .string(source)
            ]
        ))

        replacementHistory.record(
            ReplacementHistoryEntry(
                kind: historyKind,
                original: proposal.original,
                converted: proposal.candidate,
                sourceLayoutID: proposal.fromLayoutID,
                targetLayoutID: proposal.targetLayoutID,
                bundleID: proposal.bundleID
            )
        )
        return true
    }

    private func createRuleFromProposal(_ proposal: AutoFixProposal) {
        guard canCreateRule(from: proposal) else { return }
        var rules = settings().customAutoReplaceRules
        rules.removeAll { $0.source.caseInsensitiveCompare(proposal.original) == .orderedSame }
        rules.append(CustomAutoReplaceRule(
            source: proposal.original,
            target: proposal.candidate,
            createdFromRecommendation: true
        ))
        settingsWriter.setCustomAutoReplaceRules(rules)

        // Creating a rule for a word overrides an older "never replace" for it —
        // and that has to include the spelling dictionary `WordListEditing.add`
        // taught, otherwise the word keeps reading as correct and the new rule
        // never fires.
        wordList.remove(proposal.original)
    }

    private func canCreateRule(from proposal: AutoFixProposal) -> Bool {
        guard proposal.createsRuleOnAcceptance else { return false }
        let source = proposal.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = proposal.candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return !source.isEmpty
            && !target.isEmpty
            && !source.contains(where: \.isWhitespace)
            && !target.contains(where: \.isWhitespace)
    }

    private func neverReplace(_ proposal: AutoFixProposal) {
        wordList.add(proposal.original)
        clearRecovery()
    }

    private func showProposalRecovery(_ proposal: AutoFixProposal) {
        let pending = PendingProposalRecovery(
            proposal: proposal,
            expiresAt: ProcessInfo.processInfo.systemUptime + 10
        )
        pendingProposalRecovery = pending
        pendingReapply = nil
        presenter.showRecovery(
            title: AutoFixRecoveryTitle.bringBackProposal,
            near: NSEvent.mouseLocation
        ) { [weak self] in
            self?.reopenProposalRecovery()
        }
    }

    private func reopenProposalRecovery() {
        guard let pending = pendingProposalRecovery,
              pending.isValid(at: ProcessInfo.processInfo.systemUptime),
              pending.proposal.replacementAnchor.survivesLaterTyping,
              targetValidator.isReplacementAnchorValid(pending.proposal.replacementAnchor)
        else {
            clearRecovery()
            return
        }
        pendingProposalRecovery = nil
        presentProposal(pending.proposal, recordDecision: false)
    }

    private func showReapplyRecovery(_ pending: PendingReapply) {
        pendingReapply = pending
        pendingProposalRecovery = nil
        presenter.showRecovery(
            title: AutoFixRecoveryTitle.applyAgain,
            near: NSEvent.mouseLocation
        ) { [weak self] in
            self?.reapplyPendingFix()
        }
    }

    private func reapplyPendingFix() {
        guard let pending = pendingReapply,
              pending.isValid(at: ProcessInfo.processInfo.systemUptime) else {
            clearRecovery()
            return
        }
        guard let replacementResult = targetValidator.replaceAnchoredText(
            pending.replacementAnchor,
            with: pending.replacement
        ) else {
            recordMutationFailure(
                source: pending.original,
                candidate: pending.replacement,
                fromLayoutID: pending.fromLayoutID,
                targetLayoutID: pending.targetLayoutID,
                bundleID: AppContextProvider.frontmostBundleID() ?? "",
                scope: pending.original.contains(where: \.isWhitespace) ? .phrase : .word
            )
            clearRecovery()
            return
        }
        pendingReapply = nil
        if pending.changesInputLayout {
            layoutManager.switchTo(pending.targetLayoutID)
        }
        let canUndo = setPendingUndo(
            original: pending.original,
            replacement: pending.replacement,
            fromLayoutID: pending.fromLayoutID,
            targetLayoutID: pending.targetLayoutID,
            changesInputLayout: pending.changesInputLayout,
            recoveryAnchor: replacementResult.recoveryAnchor
        )
        stats.recordReplacement(text: pending.replacement)
        NotificationCenter.default.post(name: replacementNotificationName, object: nil)
        showReplacementFeedback(canUndo: canUndo)
    }

    private func clearRecovery() {
        pendingProposalRecovery = nil
        pendingReapply = nil
        presenter.dismissFixToast()
    }

    private func showReplacementFeedback(canUndo: Bool) {
        guard settings().autoFixToastEnabled else { return }
        presenter.showFixToast(
            near: NSEvent.mouseLocation,
            onClick: canUndo ? { [weak self] in self?.undoFromToast() } : nil
        )
    }

    @discardableResult
    private func setPendingUndo(
        original: String,
        replacement: String,
        fromLayoutID: String,
        targetLayoutID: String,
        changesInputLayout: Bool = true,
        recoveryAnchor: TextReplacementAnchor?
    ) -> Bool {
        implicitUndoWatch = (ProcessInfo.processInfo.systemUptime, 0, AppContextProvider.frontmostBundleID() ?? "")
        guard let recoveryAnchor else {
            lastFix = nil
            return false
        }
        lastFix = PendingUndo(
            original: original,
            replacement: replacement,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            changesInputLayout: changesInputLayout,
            timestamp: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: recoveryAnchor
        )
        return true
    }

    private func applyCustomRule(
        rule: CustomAutoReplaceRule,
        original: String,
        boundary: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let replacementResult = performAnchoredReplacement(
            original: original,
            candidate: rule.target,
            boundary: boundaryToPreserve,
            bundleID: bundleID,
            targetSession: targetSession
        ) else {
            return
        }
        AppLogger.action(logger, "Custom rule applying: sourceLength=\(rule.source.count) targetLength=\(rule.target.count)")
        updateCustomRuleDecision(candidate: rule.target, source: original)
        markDecision(outcome: .ruleApplied, reason: nil, matching: original)
        let fromLayoutID = layoutManager.getCurrentLayoutID()

        let canUndo = setPendingUndo(
            original: original,
            replacement: rule.target,
            fromLayoutID: fromLayoutID,
            targetLayoutID: fromLayoutID,
            changesInputLayout: false,
            recoveryAnchor: replacementResult.recoveryAnchor
        )

        stats.recordReplacement(text: rule.target)
        NotificationCenter.default.post(name: replacementNotificationName, object: nil)

        showReplacementFeedback(canUndo: canUndo)

        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: bundleID,
            inputLayout: fromLayoutID,
            properties: [
                "original_length": .int(original.count),
                "replacement_length": .int(rule.target.count),
                "rule_origin": .string(rule.createdFromRecommendation ? "recommendation" : "manual"),
                "source": .string("custom_rule")
            ]
        ))

        replacementHistory.record(
            ReplacementHistoryEntry(
                kind: .autoRuleApplied,
                original: original,
                converted: rule.target,
                sourceLayoutID: fromLayoutID,
                targetLayoutID: nil,
                bundleID: bundleID
            )
        )
    }

    private func beginDecision(
        source: String,
        sourceLayoutID: String,
        sourceLanguage: String,
        bundleID: String,
        algorithm: LanguageScorerAlgorithm
    ) {
        activeDecisionDraft = AutoFixDecisionDraft(
            id: UUID(),
            timestamp: Date(),
            source: source,
            selectedCandidate: nil,
            candidates: [],
            originalScore: nil,
            rawCandidateScore: nil,
            effectiveCandidateScore: nil,
            confidence: nil,
            threshold: settings().autoFixThreshold,
            proposalWindow: settings().autoFixProposalWindow,
            candidateSeparation: settings().autoFixCandidateSeparation,
            minimumWordLength: settings().autoFixMinWordLength,
            algorithm: algorithm,
            outcome: .skipped,
            reason: nil,
            scope: .word,
            sourceLayoutID: sourceLayoutID,
            targetLayoutID: nil,
            sourceLanguage: sourceLanguage,
            targetLanguage: nil,
            bundleID: bundleID.isEmpty ? nil : bundleID,
            signalKind: nil,
            candidateOrigin: nil,
            aggregateOnly: false
        )
    }

    private func finishDecision() {
        guard let draft = activeDecisionDraft else { return }
        activeDecisionDraft = nil
        decisionHistory.record(draft.observation)
    }

    private func updateDecisionCandidates(
        scoreOriginal: Double,
        candidates: [AutoFixTargetCandidate],
        threshold: Double
    ) {
        guard var draft = activeDecisionDraft else { return }
        draft.originalScore = scoreOriginal
        draft.threshold = threshold
        draft.candidates = candidates.map {
            AutoFixScoredCandidate(
                text: $0.candidate,
                targetLayoutID: $0.targetID,
                language: $0.targetLang,
                score: $0.scoreCandidate
            )
        }
        activeDecisionDraft = draft
    }

    private func selectDecisionCandidate(_ candidate: AutoFixTargetCandidate) {
        guard var draft = activeDecisionDraft else { return }
        draft.selectedCandidate = candidate.candidate
        draft.rawCandidateScore = candidate.scoreCandidate
        draft.effectiveCandidateScore = candidate.scoreCandidate
        draft.confidence = nil
        draft.targetLayoutID = candidate.targetID
        draft.targetLanguage = candidate.targetLang
        draft.candidateOrigin = .keyboardLayout
        activeDecisionDraft = draft
    }

    private func updateEffectiveDecisionScore(effectiveCandidateScore: Double, threshold: Double) {
        guard var draft = activeDecisionDraft else { return }
        draft.effectiveCandidateScore = effectiveCandidateScore
        draft.threshold = threshold
        activeDecisionDraft = draft
    }

    private func updateCustomRuleDecision(candidate: String, source: String) {
        guard var draft = activeDecisionDraft, draft.source == source else { return }
        draft.scope = .customRule
        draft.selectedCandidate = candidate
        draft.confidence = 1
        draft.candidateOrigin = .customRule
        activeDecisionDraft = draft
    }

    private func updateSpellingDecision(suggestion: String, source: String, confidence: Double) {
        guard var draft = activeDecisionDraft, draft.source == source else { return }
        draft.selectedCandidate = suggestion
        draft.candidates = []
        draft.rawCandidateScore = nil
        draft.effectiveCandidateScore = nil
        draft.confidence = confidence
        draft.targetLayoutID = draft.sourceLayoutID
        draft.targetLanguage = draft.sourceLanguage
        draft.candidateOrigin = .spelling
        activeDecisionDraft = draft
    }

    private func markDecisionAggregateOnly(matching source: String) {
        guard var draft = activeDecisionDraft, draft.source == source else { return }
        draft.aggregateOnly = true
        activeDecisionDraft = draft
    }

    private func recordPhraseDecision(
        original: String,
        candidate: String?,
        scoreOriginal: Double?,
        scoreCandidate: Double?,
        threshold: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        fromLayoutID: String,
        targetLayoutID: String,
        bundleID: String,
        outcome: AutoFixDecisionObservation.Outcome,
        reason: AutoFixSkipReason?,
        signalKind: AutoFixDecisionSignalKind? = nil
    ) {
        let scoredCandidates = candidate.flatMap { candidate in
            scoreCandidate.map {
                [AutoFixScoredCandidate(
                    text: candidate,
                    targetLayoutID: targetLayoutID,
                    language: targetLang,
                    score: $0
                )]
            }
        } ?? []
        decisionHistory.record(AutoFixDecisionObservation(
            source: original,
            selectedCandidate: candidate,
            candidates: scoredCandidates,
            originalScore: scoreOriginal,
            rawCandidateScore: scoreCandidate,
            effectiveCandidateScore: scoreCandidate,
            threshold: threshold,
            proposalWindow: settings().autoFixProposalWindow,
            candidateSeparation: settings().autoFixCandidateSeparation,
            minimumWordLength: settings().autoFixMinWordLength,
            algorithm: algorithm,
            outcome: outcome,
            reason: reason?.rawValue,
            scope: .phrase,
            sourceLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            sourceLanguage: currentLang,
            targetLanguage: targetLang,
            bundleID: bundleID.isEmpty ? nil : bundleID,
            signalKind: signalKind ?? (outcome == .replaced || outcome == .proposed ? .layoutIncident : nil),
            candidateOrigin: .keyboardLayout
        ))
    }

    private func recordDeferredSingleDecision(
        _ decision: DeferredSingleDecision,
        outcome: AutoFixDecisionObservation.Outcome,
        reason: AutoFixSkipReason?,
        signalKind: AutoFixDecisionSignalKind
    ) {
        decisionHistory.record(AutoFixDecisionObservation(
            source: decision.original,
            selectedCandidate: decision.candidate,
            candidates: [AutoFixScoredCandidate(
                text: decision.candidate,
                targetLayoutID: decision.targetLayoutID,
                language: decision.targetLang,
                score: decision.scoreCandidate
            )],
            originalScore: decision.scoreOriginal,
            rawCandidateScore: decision.scoreCandidate,
            effectiveCandidateScore: decision.scoreCandidate,
            threshold: decision.threshold,
            proposalWindow: settings().autoFixProposalWindow,
            candidateSeparation: settings().autoFixCandidateSeparation,
            minimumWordLength: settings().autoFixMinWordLength,
            algorithm: decision.algorithm,
            outcome: outcome,
            reason: reason?.rawValue,
            scope: .word,
            sourceLayoutID: decision.fromLayoutID,
            targetLayoutID: decision.targetLayoutID,
            sourceLanguage: decision.currentLang,
            targetLanguage: decision.targetLang,
            bundleID: decision.bundleID.isEmpty ? nil : decision.bundleID,
            signalKind: signalKind,
            candidateOrigin: .keyboardLayout
        ))
    }

    private func recordMutationFailure(
        source: String,
        candidate: String,
        fromLayoutID: String,
        targetLayoutID: String,
        bundleID: String,
        scope: AutoFixDecisionObservation.Scope,
        algorithm: LanguageScorerAlgorithm = .appleNL,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        candidateOrigin: AutoFixDecisionCandidateOrigin = .keyboardLayout
    ) {
        decisionHistory.record(AutoFixDecisionObservation(
            source: source,
            selectedCandidate: candidate,
            threshold: settings().autoFixThreshold,
            proposalWindow: settings().autoFixProposalWindow,
            candidateSeparation: settings().autoFixCandidateSeparation,
            minimumWordLength: settings().autoFixMinWordLength,
            algorithm: algorithm,
            outcome: .skipped,
            reason: AutoFixSkipReason.replacementNotCommitted.rawValue,
            scope: scope,
            sourceLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            sourceLanguage: sourceLanguage ?? languageHintForLayoutID(fromLayoutID),
            targetLanguage: targetLanguage ?? languageHintForLayoutID(targetLayoutID),
            bundleID: bundleID.isEmpty ? nil : bundleID,
            signalKind: .mutationFailure,
            candidateOrigin: candidateOrigin
        ))
    }

    private func markDecision(
        outcome: AutoFixDecisionObservation.Outcome,
        reason: String?,
        signalKind: AutoFixDecisionSignalKind? = nil,
        candidateOrigin: AutoFixDecisionCandidateOrigin? = nil,
        matching source: String
    ) {
        guard var draft = activeDecisionDraft, draft.source == source else { return }
        draft.outcome = outcome
        draft.reason = reason
        if let signalKind { draft.signalKind = signalKind }
        if let candidateOrigin { draft.candidateOrigin = candidateOrigin }
        activeDecisionDraft = draft
    }

    /// Skip event for "could not pin the token to an AX range", naming the AX read
    /// that actually failed.
    ///
    /// Every caller used to emit an identical bare `target_unverifiable`, which
    /// covered a missing focused element, a caret outside the typed token, a failed
    /// text readback and a target that moved — four different bugs behind one
    /// string, and no way to tell them apart from the field logs.
    private func logTargetUnverifiable(word: String, bundleID: String) {
        var extra: [String: AnalyticsValue] = [:]
        if let reason = targetValidator.lastFailureReason {
            extra["target_reason"] = .string(reason)
        }
        for (key, value) in caretMismatchProperties() {
            extra[key] = value
        }
        logSkip(.targetUnverifiable, word: word, bundleID: bundleID, extra: extra)
    }

    /// How far the caret actually moved versus what would have been accepted.
    ///
    /// Three attempts at this bug were spent theorising about why targets stopped
    /// matching; the numbers were never in the logs. They are now.
    private func caretMismatchProperties() -> [String: AnalyticsValue] {
        guard let mismatch = targetValidator.lastCaretMismatch else { return [:] }
        return [
            "caret_advance_actual": .int(mismatch.actual),
            "caret_advance_expected": .string(mismatch.expected.map(String.init).joined(separator: ","))
        ]
    }

    private func logSkip(
        _ reason: AutoFixSkipReason,
        word: String,
        bundleID: String,
        layoutID: String? = nil,
        extra: [String: AnalyticsValue] = [:]
    ) {
        AppLogger.post(logger, "auto-fix skipped: reason=\(reason.rawValue) wordLength=\(word.count)")
        markDecision(outcome: .skipped, reason: reason.rawValue, matching: word)
        var props: [String: AnalyticsValue] = [
            "reason": .string(reason.rawValue),
            "word_length": .int(word.count)
        ]
        for (k, v) in extra { props[k] = v }
        // Reuse the layout id the caller already resolved on the hot path; only query TIS again
        // when a caller (rare skip reasons) didn't pass one.
        eventLog.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixSkipped,
            frontmostBundleID: bundleID,
            inputLayout: layoutID ?? layoutManager.getCurrentLayoutID(),
            properties: props
        ))
    }

    private func performAnchoredReplacement(
        original: String,
        candidate: String,
        boundary: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?,
        boundaryCaret: Int? = nil,
        allowsKeyboardFallback: Bool = true
    ) -> TextReplacementResult? {
        guard let targetSession else {
            logSkip(.targetUnverifiable, word: original, bundleID: bundleID, extra: [
                "target_reason": .string("missing_session")
            ])
            return nil
        }
        guard let anchor = targetValidator.captureReplacementAnchor(
            for: targetSession,
            expectedBundleID: bundleID,
            source: original,
            boundary: boundary,
            boundaryCaret: boundaryCaret,
            allowsKeyboardFallback: allowsKeyboardFallback
        ) else {
            logTargetUnverifiable(word: original, bundleID: bundleID)
            return nil
        }
        guard let replacementResult = targetValidator.replaceAnchoredText(anchor, with: candidate) else {
            logSkip(.replacementNotCommitted, word: original, bundleID: bundleID, extra: [
                "target_reason": .string(targetValidator.lastReplaceFailureReason ?? "editor_content_mismatch")
            ])
            return nil
        }
        return replacementResult
    }

    private func switchLayoutIfNeeded(
        fromLayoutID: String,
        targetLayoutID: String,
        scope: ReplacementScope
    ) {
        let policy = AutoFixLayoutSwitchPolicy(rawValue: settings().autoFixLayoutSwitchPolicy) ?? .adaptive

        switch policy {
        case .alwaysSwitchToReplacementLayout:
            layoutManager.switchTo(targetLayoutID)
            return
        case .keepCurrentLayout:
            return
        case .adaptive:
            break
        }

        switch scope {
        case .phrase:
            layoutManager.switchTo(targetLayoutID)
        case .customRule:
            return
        case .singleToken:
            if var current = consecutiveReplacementDirection,
               current.fromLayoutID == fromLayoutID,
               current.targetLayoutID == targetLayoutID {
                current.count += 1
                consecutiveReplacementDirection = current
            } else {
                consecutiveReplacementDirection = AutoFixReplacementDirection(
                    fromLayoutID: fromLayoutID,
                    targetLayoutID: targetLayoutID,
                    count: 1
                )
            }

            if (consecutiveReplacementDirection?.count ?? 0) >= 2 {
                layoutManager.switchTo(targetLayoutID)
            }
        }
    }

    private func isResetKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Escape, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return true
        default:
            return false
        }
    }

    private func isWordBoundary(keyCode: UInt16, typedString: String) -> Bool {
        AutoFixDecision.isWordBoundary(keyCode: keyCode, typedString: typedString)
    }

    /// Whether this key event is the user's configured shortcut.
    ///
    /// Only the four device-independent modifiers are compared: the flags a tap reports
    /// also carry state a recorded shortcut never has (numeric keypad, Caps Lock), and
    /// demanding raw equality would never match.
    nonisolated static func matchesShortcut(
        keyCode: UInt16,
        flags: CGEventFlags,
        carbonKeyCode: Int?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard let carbonKeyCode, Int(keyCode) == carbonKeyCode else { return false }
        var pressed: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { pressed.insert(.command) }
        if flags.contains(.maskShift) { pressed.insert(.shift) }
        if flags.contains(.maskAlternate) { pressed.insert(.option) }
        if flags.contains(.maskControl) { pressed.insert(.control) }
        return pressed == modifiers.intersection([.command, .shift, .option, .control])
    }

    /// The undo shortcut reaches the tap on keyDown, but the host's shortcut handler fires
    /// on keyUp. Every reset path below clears `lastFix`, so without this the handler
    /// always found nothing to undo — a Cmd chord through `processEvent`'s command branch,
    /// anything else through the reset-key or boundary branch.
    private func isUndoShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard let shortcut = undoShortcut() else { return false }
        return Self.matchesShortcut(
            keyCode: keyCode,
            flags: flags,
            carbonKeyCode: shortcut.carbonKeyCode,
            modifiers: shortcut.modifiers
        )
    }

    private func languageHintForLayoutID(_ layoutID: String) -> String {
        AutoFixDecision.languageHintForLayoutID(layoutID)
    }
}

private struct WordBuffer {
    private(set) var text = ""
    private(set) var keyCodes: [UInt16] = []

    mutating func append(string: String, keyCode: UInt16) {
        text.append(string)
        keyCodes.append(keyCode)
    }

    mutating func popLast() {
        guard !text.isEmpty else { return }
        text.removeLast()
        if !keyCodes.isEmpty { keyCodes.removeLast() }
    }

    mutating func reset() {
        text = ""
        keyCodes.removeAll()
    }
}

private enum DeferredSingleAction {
    case none
    case replace
    case proposal(force: Bool)
}

private struct DeferredSingleDecision {
    let action: DeferredSingleAction
    let original: String
    let candidate: String
    let boundary: String
    let fromLayoutID: String
    let targetLayoutID: String
    let scoreOriginal: Double
    let scoreCandidate: Double
    let threshold: Double
    let algorithm: LanguageScorerAlgorithm
    let currentLang: String
    let targetLang: String
    let bundleID: String
    let targetSession: AutoFixTargetSession?
    /// The caret as it stood at the boundary that produced this decision, captured
    /// before the grace timer let the user type past it.
    let boundaryCaret: Int?
}

private struct LayoutIncidentContext {
    let fromLayoutID: String
    let targetLayoutID: String
    let algorithm: LanguageScorerAlgorithm
    let currentLang: String
    let targetLang: String
    let bundleID: String
    let canMutateDirectly: Bool
    let allowsProposal: Bool
    let threshold: Double
    let targetSession: AutoFixTargetSession?

    func matches(_ other: LayoutIncidentContext) -> Bool {
        fromLayoutID == other.fromLayoutID
            && targetLayoutID == other.targetLayoutID
            && algorithm == other.algorithm
            && currentLang == other.currentLang
            && targetLang == other.targetLang
            && bundleID == other.bundleID
            // A policy change mid-run must not inherit the first token's permissions.
            && canMutateDirectly == other.canMutateDirectly
            && allowsProposal == other.allowsProposal
    }
}


private struct PendingUndo {
    let original: String
    let replacement: String
    let fromLayoutID: String
    let targetLayoutID: String
    let changesInputLayout: Bool
    let timestamp: TimeInterval
    let replacementAnchor: TextReplacementAnchor
}

private struct PendingReapply {
    let original: String
    let replacement: String
    let fromLayoutID: String
    let targetLayoutID: String
    let changesInputLayout: Bool
    let replacementAnchor: TextReplacementAnchor
    let expiresAt: TimeInterval

    func isValid(at timestamp: TimeInterval) -> Bool {
        timestamp < expiresAt
    }
}

private struct AutoFixDecisionDraft {
    let id: UUID
    let timestamp: Date
    let source: String
    var selectedCandidate: String?
    var candidates: [AutoFixScoredCandidate]
    var originalScore: Double?
    var rawCandidateScore: Double?
    var effectiveCandidateScore: Double?
    var confidence: Double?
    var threshold: Double
    let proposalWindow: Double
    let candidateSeparation: Double
    let minimumWordLength: Int
    let algorithm: LanguageScorerAlgorithm
    var outcome: AutoFixDecisionObservation.Outcome
    var reason: String?
    var scope: AutoFixDecisionObservation.Scope
    let sourceLayoutID: String?
    var targetLayoutID: String?
    let sourceLanguage: String?
    var targetLanguage: String?
    let bundleID: String?
    var signalKind: AutoFixDecisionSignalKind?
    var candidateOrigin: AutoFixDecisionCandidateOrigin?
    var aggregateOnly: Bool

    var observation: AutoFixDecisionObservation {
        AutoFixDecisionObservation(
            id: id,
            timestamp: timestamp,
            source: source,
            selectedCandidate: selectedCandidate,
            candidates: candidates,
            originalScore: originalScore,
            rawCandidateScore: rawCandidateScore,
            effectiveCandidateScore: effectiveCandidateScore,
            confidence: confidence,
            threshold: threshold,
            proposalWindow: proposalWindow,
            candidateSeparation: candidateSeparation,
            minimumWordLength: minimumWordLength,
            algorithm: algorithm,
            outcome: outcome,
            reason: reason,
            scope: scope,
            sourceLayoutID: sourceLayoutID,
            targetLayoutID: targetLayoutID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            bundleID: bundleID,
            signalKind: signalKind,
            candidateOrigin: candidateOrigin,
            aggregateOnly: aggregateOnly
        )
    }
}

private enum ReplacementScope {
    case singleToken
    case phrase
    case customRule
}

private func autoFixCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<AutoFixController>.fromOpaque(userInfo).takeUnretainedValue()
    if controller.handleProposalShortcutSynchronously(type: type, event: event) {
        return nil
    }
    controller.handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

