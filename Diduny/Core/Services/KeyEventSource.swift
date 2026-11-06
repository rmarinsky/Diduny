import AppKit
import KeyboardShortcuts

// MARK: - Key events (test-plan 2.4)

/// A key event as plain values, so the press rules can be tested without `NSEvent`.
enum KeyEvent: Equatable {
    case flagsChanged(keyCode: UInt16, flagsRawValue: UInt, timestamp: TimeInterval)
    /// `characters` is `charactersIgnoringModifiers`, used only for a key's label.
    case keyDown(keyCode: UInt16, modifiersRawValue: UInt, isRepeat: Bool, timestamp: TimeInterval, characters: String? = nil)

    init?(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            self = .flagsChanged(
                keyCode: event.keyCode,
                flagsRawValue: event.modifierFlags.rawValue,
                timestamp: event.timestamp
            )
        case .keyDown:
            self = .keyDown(
                keyCode: event.keyCode,
                modifiersRawValue: event.modifierFlags.rawValue,
                isRepeat: event.isARepeat,
                timestamp: event.timestamp,
                characters: event.charactersIgnoringModifiers
            )
        default:
            return nil
        }
    }
}

protocol KeyEventSource: AnyObject {
    var isActive: Bool { get }
    /// Starts delivering events to `handler`, replacing an earlier handler.
    func start(_ handler: @escaping (KeyEvent) -> Void)
    func stop()
}

/// Today's global + local monitor pair. It only observes: the local monitor returns every event
/// and a global monitor cannot consume, so other apps always get their typing.
final class NSEventKeySource: KeyEventSource {
    private let mask: NSEvent.EventTypeMask
    private var monitors: [Any] = []

    init(_ mask: NSEvent.EventTypeMask) {
        self.mask = mask
    }

    var isActive: Bool {
        !monitors.isEmpty
    }

    func start(_ handler: @escaping (KeyEvent) -> Void) {
        stop()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            if let keyEvent = KeyEvent(event) { handler(keyEvent) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            if let keyEvent = KeyEvent(event) { handler(keyEvent) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

// MARK: - Carbon hotkeys (test-plan 2.4)

/// The part of `KeyboardShortcuts` the services use, so tests can fire a name without Carbon.
protocol HotkeyRegistrar: AnyObject {
    func onKeyDown(for name: KeyboardShortcuts.Name, handler: @escaping () -> Void)
    func removeHandler(for name: KeyboardShortcuts.Name)
    func disable(_ name: KeyboardShortcuts.Name)
    func enable(_ name: KeyboardShortcuts.Name)
    func isEnabled(_ name: KeyboardShortcuts.Name) -> Bool
    func getShortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name)
}

final class KeyboardShortcutsRegistrar: HotkeyRegistrar {
    static let shared = KeyboardShortcutsRegistrar()

    func onKeyDown(for name: KeyboardShortcuts.Name, handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: name, action: handler)
    }

    func removeHandler(for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.removeHandler(for: name)
    }

    func disable(_ name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.disable(name)
    }

    func enable(_ name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.enable(name)
    }

    func isEnabled(_ name: KeyboardShortcuts.Name) -> Bool {
        KeyboardShortcuts.isEnabled(for: name)
    }

    func getShortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: name)
    }

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }
}
