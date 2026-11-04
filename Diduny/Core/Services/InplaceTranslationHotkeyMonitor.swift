import AppKit

/// Global + local monitor that feeds modifier changes and key-downs into
/// `InplaceTranslationGesture` and calls `onTrigger` on a completed double tap.
final class InplaceTranslationHotkeyMonitor {
    private var gesture = InplaceTranslationGesture()
    private var monitors: [Any] = []

    var onTrigger: (() -> Void)?
    /// Keys a push-to-talk shortcut owns. A tap that uses one of them is not part of the gesture.
    var reservedKeys: Set<PushToTalkKey> = []

    var isRunning: Bool {
        !monitors.isEmpty
    }

    func start() {
        guard !isRunning else { return }
        gesture.reset()

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
        Log.app.info("Instant translation gesture monitor started")
    }

    func stop() {
        guard isRunning else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        gesture.reset()
        Log.app.info("Instant translation gesture monitor stopped")
    }

    private func handle(_ event: NSEvent) {
        let gestureEvent: InplaceTranslationGesture.Event
        switch event.type {
        case .keyDown:
            gestureEvent = .keyDown
        case .flagsChanged:
            gestureEvent = .modifiersChanged(Self.modifiers(from: event.modifierFlags, reserved: reservedKeys), at: event.timestamp)
        default:
            return
        }

        if gesture.handle(gestureEvent) {
            onTrigger?()
        }
    }

    static func modifiers(
        from flags: NSEvent.ModifierFlags,
        reserved: Set<PushToTalkKey> = []
    ) -> InplaceTranslationGesture.Modifiers {
        var result: InplaceTranslationGesture.Modifiers = []
        if reserved.contains(where: { key in sideMask(key).map { flags.rawValue & $0 != 0 } ?? false }) {
            result.insert(.other)
        }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) || flags.contains(.control) { result.insert(.other) }
        return result
    }

    private static func sideMask(_ key: PushToTalkKey) -> UInt? {
        typealias Mask = PushToTalkService.DeviceModifierMask
        switch key {
        case .leftOption: return Mask.leftOption
        case .rightOption: return Mask.rightOption
        case .leftCommand: return Mask.leftCommand
        case .rightCommand: return Mask.rightCommand
        default: return nil
        }
    }
}
