import AppKit
import Foundation

/// Cancels an active recording when the stored cancel key (`escapeCancelShortcut`, unset = Esc) is
/// pressed 1x, 2x or 3x within the threshold. It only observes keys: the front app still gets them,
/// which is why the key must be Esc, a bare F key, or a key with ⌘ ⌥ ⌃ (05 2.5).
@MainActor
final class EscapeCancelService: ObservableObject {
    static let shared = EscapeCancelService()

    private var lastPressTime: TimeInterval?
    private var consecutivePressCount = 0
    private let pressThreshold: TimeInterval = 1.5
    private var timeoutWork: (any ScheduledWork)?
    private var isActive = false

    private let settings: SettingsStorage
    private let source: KeyEventSource
    private let clock: MonotonicClock
    private let scheduler: DelayScheduler
    private let captureSession: ShortcutCaptureSession
    private let playsSound: Bool

    /// Called when recording should be cancelled (after required press count confirmed), with
    /// "Keep the audio when cancelled" (`escapeCancelSaveAudio`) read at that moment.
    var onCancel: ((_ keepAudio: Bool) -> Void)?

    /// Called on intermediate presses so UI can explain how many are left.
    var onProgressEscape: ((Int, Int) -> Void)?

    private let tinkSound = NSSound(named: .init("Tink"))

    init(
        settings: SettingsStorage = .shared,
        source: KeyEventSource = NSEventKeySource(.keyDown),
        clock: MonotonicClock = SystemClock(),
        scheduler: DelayScheduler = TaskDelayScheduler(),
        captureSession: ShortcutCaptureSession = .shared,
        playsSound: Bool = true
    ) {
        self.settings = settings
        self.source = source
        self.clock = clock
        self.scheduler = scheduler
        self.captureSession = captureSession
        self.playsSound = playsSound
    }

    /// Activate shortcut monitoring (call when recording starts)
    func activate() {
        guard !isActive else { return }
        isActive = true
        resetPressState()

        // NSEvent monitors call back on the main thread.
        source.start { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }

        Log.app.debug("Cancel shortcut handler activated")
    }

    /// Deactivate shortcut monitoring (call when recording stops)
    func deactivate() {
        isActive = false
        source.stop()
        resetPressState()
        onCancel = nil
        onProgressEscape = nil

        Log.app.debug("Cancel shortcut handler deactivated")
    }

    private func handle(_ event: KeyEvent) {
        guard isActive, !captureSession.isActive else { return }
        guard settings.escapeCancelEnabled else {
            resetPressState()
            return
        }
        guard settings.escapeCancelShortcut.matches(event) else { return }
        processEscapePress(at: clock.now)
    }

    func processEscapePress(at now: TimeInterval) {
        let requiredPressCount = settings.escapeCancelPressCount

        if let lastPressTime, now - lastPressTime <= pressThreshold {
            consecutivePressCount += 1
        } else {
            consecutivePressCount = 1
        }
        lastPressTime = now

        if consecutivePressCount >= requiredPressCount {
            Log.app.info("\(requiredPressCount)x cancel key detected - cancelling recording")
            resetPressState()
            onCancel?(settings.escapeCancelSaveAudio)
        } else {
            Log.app.debug("Cancel key press \(self.consecutivePressCount)/\(requiredPressCount) - waiting for confirmation")
            if playsSound { tinkSound?.play() }
            onProgressEscape?(consecutivePressCount, requiredPressCount)
            timeoutWork?.cancel()
            timeoutWork = scheduler.schedule(after: pressThreshold) { [weak self] in
                MainActor.assumeIsolated { self?.resetPressState() }
            }
        }
    }

    private func resetPressState() {
        lastPressTime = nil
        consecutivePressCount = 0
        timeoutWork?.cancel()
        timeoutWork = nil
    }
}
