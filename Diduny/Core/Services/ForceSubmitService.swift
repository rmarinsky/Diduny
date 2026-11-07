import AppKit
import Foundation
import KeyboardShortcuts

/// Pure decisions for the "Force submit" shortcut.
enum ForceSubmitPolicy {
    /// Submit only when the shortcut was used and the text was actually pasted.
    static func shouldSubmit(armed: Bool, autoPaste: Bool, hasText: Bool, pasteSucceeded: Bool) -> Bool {
        armed && autoPaste && hasText && pasteSucceeded
    }

    /// The key combination sent after paste is always Command-Return, whatever trigger shortcut is recorded.
    static let submitKeyCode: CGKeyCode = 36
    static let submitFlags: CGEventFlags = .maskCommand
}

/// Registers the Force submit hotkey only while a dictation/translation recording is active,
/// so it never swallows the key combination in other apps when idle.
@MainActor
final class ForceSubmitService {
    static let shared = ForceSubmitService()

    private(set) var isActive = false
    private(set) var isArmed = false
    private var onTrigger: (() -> Void)?
    private var counter = PressCounter()

    private let settings: SettingsStorage
    private let registrar: HotkeyRegistrar
    private let clock: MonotonicClock
    private let captureSession: ShortcutCaptureSession
    /// Kept for the service's lifetime; the block holds `self` weakly.
    private var captureEndObserver: NSObjectProtocol?

    init(
        settings: SettingsStorage = .shared,
        registrar: HotkeyRegistrar = KeyboardShortcutsRegistrar.shared,
        clock: MonotonicClock = SystemClock(),
        captureSession: ShortcutCaptureSession = .shared
    ) {
        self.settings = settings
        self.registrar = registrar
        self.clock = clock
        self.captureSession = captureSession
        captureEndObserver = captureSession.observeEnd { [weak self] in
            MainActor.assumeIsolated { self?.reassertRegistration() }
        }
    }

    deinit {
        if let captureEndObserver { captureSession.notifications.removeObserver(captureEndObserver) }
    }

    func activate(onTrigger: @escaping () -> Void) {
        guard settings.forceSubmitEnabled else {
            deactivate()
            return
        }
        isArmed = false
        counter.reset()
        self.onTrigger = onTrigger
        guard !isActive else { return }
        isActive = true
        registrar.removeHandler(for: .forceSubmit)
        // Carbon delivers hotkeys on the main thread.
        registrar.onKeyDown(for: .forceSubmit) { [weak self] in
            MainActor.assumeIsolated { self?.trigger() }
        }
        reassertRegistration()
    }

    /// Live only while a recording is active and no shortcut is being captured.
    private func reassertRegistration() {
        if isActive, !captureSession.isActive {
            registrar.enable(.forceSubmit)
        } else {
            registrar.disable(.forceSubmit)
        }
    }

    /// Unregisters the hotkey. Keeps the armed flag so the stop pipeline can still submit after paste.
    func deactivate() {
        isActive = false
        onTrigger = nil
        counter.reset()
        registrar.removeHandler(for: .forceSubmit)
        registrar.disable(.forceSubmit)
    }

    func disarm() {
        isArmed = false
    }

    /// Returns whether Force submit was requested for the current recording, and clears the flag.
    func consumeArmed() -> Bool {
        defer { isArmed = false }
        return isArmed
    }

    private func trigger() {
        guard isActive, !isArmed, !captureSession.isActive else { return }
        guard counter.register(at: clock.now, required: settings.forceSubmitPressCount) else { return }
        isArmed = true
        onTrigger?()
    }
}
