import AppKit
import Observation
import PapugaKit

/// What the host needs from the typing engine; `TypingEngine` in the app, a fake in tests.
@MainActor
protocol TypingEngineControlling: AnyObject {
    func start() -> Bool
    func stop()
    func noteExternalEdit()
    func undoLastFix()
    func layoutConversion(of text: String) -> TypingLayoutConversion?
    func finishLayoutConversion(_ conversion: TypingLayoutConversion)
}

extension TypingEngine: TypingEngineControlling {}

/// Runs the typing engine (fixes while typing) while `typing.enabled` is on, Accessibility is granted and no
/// standalone Papuga is running.
/// `reconcile()` is the only place that starts or stops it.
@MainActor
@Observable
final class TypingEngineHost {
    /// The app's host; `AppDelegate` activates it and the Typing page reads its `state`.
    static let shared = TypingEngineHost()

    enum State: Equatable {
        case stopped
        case running
        /// The setting is on and Accessibility is granted, but the system refused the key event tap.
        /// The next `reconcile()` tries again.
        case startFailed
        /// A standalone Papuga is running. Two engines must never fix the same word, so this one waits.
        case papugaRunning
    }

    nonisolated static let papugaBundleIDs = ["ua.com.rmarinsky.papuga", "ua.com.rmarinsky.papuga.dev"]

    private(set) var state: State = .stopped {
        didSet {
            if (oldValue == .running) != (state == .running) { onRunningChanged?(state == .running) }
        }
    }

    /// Called when the engine starts or stops running; the app registers the Undo hotkey only while it runs.
    @ObservationIgnored var onRunningChanged: ((Bool) -> Void)?

    @ObservationIgnored private let settings: SettingsStorage
    @ObservationIgnored private let isAccessibilityGranted: () -> Bool
    @ObservationIgnored private let isPapugaRunning: () -> Bool
    @ObservationIgnored private let makeEngine: @MainActor () -> TypingEngineControlling
    /// Built on the first start, so a user who never turns Typing on pays nothing.
    @ObservationIgnored private var engine: TypingEngineControlling?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let convertMonitor: TypingConvertMonitor
    @ObservationIgnored private var clipboard: ClipboardService = .shared
    @ObservationIgnored private var isConverting = false

    /// The Convert pair while it is listened for. Push-to-talk ignores a press of its key while the other key
    /// of this pair is down, so the pair pressed twice is never also a dictation tap.
    var activeConvertPair: TypingConvertPair? {
        convertMonitor.pair
    }

    init(
        settings: SettingsStorage = .shared,
        isAccessibilityGranted: @escaping () -> Bool = ClipboardService.isAccessibilityGranted,
        isPapugaRunning: @escaping () -> Bool = TypingEngineHost.isStandalonePapugaRunning,
        makeEngine: (@MainActor () -> TypingEngineControlling)? = nil,
        convertMonitor: TypingConvertMonitor = TypingConvertMonitor()
    ) {
        self.settings = settings
        self.convertMonitor = convertMonitor
        self.isAccessibilityGranted = isAccessibilityGranted
        self.isPapugaRunning = isPapugaRunning
        self.makeEngine = makeEngine ?? {
            TypingEngine(
                storageDirectory: RecordingsLibraryStorage.defaultAppDirectory.appendingPathComponent("Typing"),
                settings: { settings.typingSettings },
                logSubsystem: Log.subsystem,
                hintPresenter: TypingHintPresenter(settings: settings),
                undoShortcut: { settings.typingUndoShortcut },
                onReplacementRecorded: { text in MainActor.assumeIsolated { TypingDailyStatsStore.shared.recordFix(text: text) } },
                onReplacementReversed: { text in MainActor.assumeIsolated { TypingDailyStatsStore.shared.reverseFix(text: text) } },
                onCadenceGapWritten: { settings.typingCadenceAverageGap = $0 },
                onRulesWritten: { settings.typingCustomReplaceRules = $0 },
                onWordAdded: { settings.addTypingNeverFixWord($0) },
                onWordRemoved: { settings.removeTypingNeverFixWord($0) },
                onWordObserved: { observation in MainActor.assumeIsolated { VocabularyStore.shared.observe(observation) } }
            )
        }
        convertMonitor.onTrigger = { [weak self] in
            MainActor.assumeIsolated { self?.convertSelection() }
        }
    }

    /// Starts following the setting, app activation (a permission may have changed), Papuga launching or
    /// quitting and Diduny's own pastes, then reconciles once.
    func activate(clipboard: ClipboardService) {
        self.clipboard = clipboard
        clipboard.onShortcutPosted = { [weak self] in self?.noteExternalEdit() }
        guard observers.isEmpty else { return }
        for name in [Notification.Name.typingSettingsChanged, NSApplication.didBecomeActiveNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
            observers.append(observer)
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier, Self.papugaBundleIDs.contains(bundleID) else { return }
                MainActor.assumeIsolated { self?.reconcile() }
            }
            observers.append(observer)
        }
        reconcile()
    }

    func reconcile() {
        defer { convertMonitor.listen(for: state == .running && settings.typingConvertEnabled ? settings.typingConvertPair : nil) }
        guard settings.typingEnabled, isAccessibilityGranted() else {
            stop()
            return
        }
        guard !isPapugaRunning() else {
            stop()
            state = .papugaRunning
            return
        }
        guard state != .running else { return }
        let engine = engine ?? makeEngine()
        self.engine = engine
        if engine.start() {
            state = .running
            Log.app.info("[Typing] engine started")
        } else {
            state = .startFailed
            Log.app.error("[Typing] engine did not start: the key event tap was refused")
        }
    }

    func stop() {
        if state == .running {
            engine?.stop()
            Log.app.info("[Typing] engine stopped")
        }
        state = .stopped
    }

    nonisolated static func isStandalonePapugaRunning() -> Bool {
        papugaBundleIDs.contains { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
        }
    }

    /// Diduny changed the focused text itself (paste, copy, submit): the engine drops the word it was following.
    func noteExternalEdit() {
        guard state == .running else { return }
        engine?.noteExternalEdit()
    }

    /// The Convert pair was pressed twice: the selection is retyped in the next layout and the layout switches.
    func convertSelection() {
        guard state == .running, !isConverting, let engine else { return }
        isConverting = true
        Task { @MainActor in
            defer { isConverting = false }
            ClipboardHistoryService.shared.suspend()
            defer { ClipboardHistoryService.shared.resume() }
            do {
                let conversion = try await clipboard.replaceSelection { text in
                    engine.layoutConversion(of: text).map { (text: $0.converted, result: $0) }
                }
                if let conversion {
                    engine.finishLayoutConversion(conversion)
                    VocabularyStore.shared.observeManualSwitch(from: conversion.original, to: conversion.converted)
                } else {
                    Log.app.info("[Typing] convert: nothing selected or no other layout")
                }
            } catch {
                Log.app.error("[Typing] convert failed: \(error.localizedDescription)")
            }
        }
    }

    /// The "Undo the last layout fix" shortcut. Does nothing while the engine is not running.
    func undoLastFix() {
        guard state == .running else { return }
        engine?.undoLastFix()
    }
}
