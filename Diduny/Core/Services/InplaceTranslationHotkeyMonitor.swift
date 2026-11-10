import AppKit
import KeyboardShortcuts

/// Runs Translate in place from exactly one path (ADR-0012 D8):
/// - a modifier chord: a key source (global + local monitors that never consume) feeds
///   `InplaceTranslationGesture`;
/// - a key chord: the Carbon hotkey `.inplaceTranslation`, which consumes the keystroke, counted
///   with the shared `PressCounter`.
final class InplaceTranslationHotkeyMonitor {
    private let source: KeyEventSource
    private let registrar: HotkeyRegistrar
    private let clock: MonotonicClock
    private let captureSession: ShortcutCaptureSession

    private var gesture = InplaceTranslationGesture()
    private var keyChordCounter = PressCounter()
    private var isKeyChordRegistered = false
    private var captureEndObserver: NSObjectProtocol?
    private(set) var shortcut: InplaceTranslationShortcut = .default
    private(set) var pressCount = 2

    var onTrigger: (() -> Void)?
    /// Keys a push-to-talk shortcut owns. A tap that uses one of them is not part of the gesture.
    var reservedKeys: Set<PushToTalkKey> = []

    var isRunning: Bool {
        source.isActive || isKeyChordRegistered
    }

    init(
        source: KeyEventSource = NSEventKeySource([.flagsChanged, .keyDown]),
        registrar: HotkeyRegistrar = KeyboardShortcutsRegistrar.shared,
        clock: MonotonicClock = SystemClock(),
        captureSession: ShortcutCaptureSession = .shared
    ) {
        self.source = source
        self.registrar = registrar
        self.clock = clock
        self.captureSession = captureSession
        captureEndObserver = captureSession.observeEnd { [weak self] in
            self?.reassertKeyChord()
        }
    }

    deinit {
        if let captureEndObserver {
            captureSession.notifications.removeObserver(captureEndObserver)
        }
    }

    /// Sets the stored kind and count; a running monitor switches paths at once.
    func configure(shortcut: InplaceTranslationShortcut, pressCount: Int) {
        guard shortcut != self.shortcut || pressCount != self.pressCount else { return }
        let wasRunning = isRunning
        stop()
        self.shortcut = shortcut
        self.pressCount = pressCount
        if wasRunning { start() }
    }

    func start() {
        guard !isRunning else { return }
        switch shortcut {
        case let .modifierChord(families):
            gesture = InplaceTranslationGesture(chord: .init(families), pressCount: pressCount)
            source.start { [weak self] event in
                self?.handle(event)
            }
        case .keyChord:
            keyChordCounter.reset()
            registrar.removeHandler(for: .inplaceTranslation)
            registrar.onKeyDown(for: .inplaceTranslation) { [weak self] in
                self?.handleKeyChordPress()
            }
            isKeyChordRegistered = true
            reassertKeyChord()
        }
        Log.app.info("Instant translation monitor started")
    }

    /// Stops both paths. Always unregisters the key chord, so a chord the package registered on
    /// save never stays live while the row is off or a modifier chord is set.
    func stop() {
        let wasRunning = isRunning
        source.stop()
        registrar.removeHandler(for: .inplaceTranslation)
        registrar.disable(.inplaceTranslation)
        isKeyChordRegistered = false
        gesture.reset()
        keyChordCounter.reset()
        if wasRunning { Log.app.info("Instant translation monitor stopped") }
    }

    /// The key chord is live only while this path runs and no shortcut is being captured.
    private func reassertKeyChord() {
        if isKeyChordRegistered, !captureSession.isActive {
            registrar.enable(.inplaceTranslation)
        } else {
            registrar.disable(.inplaceTranslation)
        }
    }

    private func handle(_ event: KeyEvent) {
        guard !captureSession.isActive else {
            gesture.reset()
            return
        }
        guard case let .modifierChord(chord) = shortcut else { return }

        let gestureEvent: InplaceTranslationGesture.Event
        switch event {
        case .keyDown:
            gestureEvent = .keyDown
        case let .flagsChanged(_, flagsRawValue, timestamp):
            gestureEvent = .modifiersChanged(
                Self.modifiers(from: NSEvent.ModifierFlags(rawValue: flagsRawValue), reserved: reservedKeys, chord: chord),
                at: timestamp
            )
        }

        if gesture.handle(gestureEvent) {
            onTrigger?()
        }
    }

    private func handleKeyChordPress() {
        guard !captureSession.isActive else { return }
        if keyChordCounter.register(at: clock.now, required: pressCount) {
            onTrigger?()
        }
    }

    /// Maps flags to gesture modifiers: chord families as themselves; another family, or a side a
    /// push-to-talk key owns, as `.other`. Caps Lock and Fn are ignored.
    static func modifiers(
        from flags: NSEvent.ModifierFlags,
        reserved: Set<PushToTalkKey> = [],
        chord: ModifierFamilies = .optionCommand
    ) -> InplaceTranslationGesture.Modifiers {
        var result: InplaceTranslationGesture.Modifiers = []
        if reserved.contains(where: { key in sideMask(key).map { flags.rawValue & $0 != 0 } ?? false }) {
            result.insert(.other)
        }
        let held = ModifierFamilies(flags: flags)
        for family in [ModifierFamilies.option, .command, .control, .shift] where held.contains(family) {
            result.insert(chord.contains(family) ? InplaceTranslationGesture.Modifiers(family) : .other)
        }
        return result
    }

    private static func sideMask(_ key: PushToTalkKey) -> UInt? {
        typealias Mask = PushToTalkService.DeviceModifierMask
        switch key {
        case .leftOption: return Mask.leftOption
        case .rightOption: return Mask.rightOption
        case .leftCommand: return Mask.leftCommand
        case .rightCommand: return Mask.rightCommand
        case .leftControl: return Mask.leftControl
        case .rightControl: return Mask.rightControl
        case .leftShift: return Mask.leftShift
        case .rightShift: return Mask.rightShift
        default: return nil
        }
    }
}
