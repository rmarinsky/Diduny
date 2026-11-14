import AppKit
import PapugaKit

/// What the host needs from the typing engine; `TypingEngine` in the app, a fake in tests.
@MainActor
protocol TypingEngineControlling: AnyObject {
    func start() -> Bool
    func stop()
    func noteExternalEdit()
}

extension TypingEngine: TypingEngineControlling {}

/// Runs the typing engine (fixes while typing) while `typing.enabled` is on and Accessibility is granted.
/// `reconcile()` is the only place that starts or stops it.
@MainActor
final class TypingEngineHost {
    enum State: Equatable {
        case stopped
        case running
        /// The setting is on and Accessibility is granted, but the system refused the key event tap.
        /// The next `reconcile()` tries again.
        case startFailed
    }

    private(set) var state: State = .stopped

    private let settings: SettingsStorage
    private let isAccessibilityGranted: () -> Bool
    private let makeEngine: @MainActor () -> TypingEngineControlling
    /// Built on the first start, so a user who never turns Typing on pays nothing.
    private var engine: TypingEngineControlling?
    private var observers: [NSObjectProtocol] = []

    init(
        settings: SettingsStorage = .shared,
        isAccessibilityGranted: @escaping () -> Bool = ClipboardService.isAccessibilityGranted,
        makeEngine: (@MainActor () -> TypingEngineControlling)? = nil
    ) {
        self.settings = settings
        self.isAccessibilityGranted = isAccessibilityGranted
        self.makeEngine = makeEngine ?? {
            TypingEngine(
                storageDirectory: RecordingsLibraryStorage.defaultAppDirectory.appendingPathComponent("Typing"),
                settings: { settings.typingSettings },
                logSubsystem: Log.subsystem,
                onCadenceGapWritten: { settings.typingCadenceAverageGap = $0 }
            )
        }
    }

    /// Starts following the setting, app activation (a permission may have changed) and Diduny's own
    /// pastes, then reconciles once.
    func activate(clipboard: ClipboardService) {
        clipboard.onShortcutPosted = { [weak self] in self?.noteExternalEdit() }
        guard observers.isEmpty else { return }
        for name in [Notification.Name.typingSettingsChanged, NSApplication.didBecomeActiveNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
            observers.append(observer)
        }
        reconcile()
    }

    func reconcile() {
        guard settings.typingEnabled, isAccessibilityGranted() else {
            stop()
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

    /// Diduny changed the focused text itself (paste, copy, submit): the engine drops the word it was following.
    func noteExternalEdit() {
        guard state == .running else { return }
        engine?.noteExternalEdit()
    }
}
