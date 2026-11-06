import AppKit
@testable import Diduny
import Foundation
import KeyboardShortcuts

/// Time that moves only when a test says so (test-plan 2.3).
final class ManualClock: MonotonicClock {
    var now: TimeInterval

    init(_ now: TimeInterval = 0) {
        self.now = now
    }

    func advance(by delta: TimeInterval) {
        now += delta
    }
}

/// Runs due work synchronously inside `advance`, in deadline order. Also a clock, so one object can
/// drive both the press times and the timeouts of a service.
final class ManualScheduler: DelayScheduler, MonotonicClock {
    private final class Work: ScheduledWork {
        let deadline: TimeInterval
        let order: Int
        var action: (() -> Void)?

        init(deadline: TimeInterval, order: Int, action: @escaping () -> Void) {
            self.deadline = deadline
            self.order = order
            self.action = action
        }

        func cancel() {
            action = nil
        }
    }

    /// Sums such as 1.19 + 0.01 must reach a 1.2 s deadline.
    private static let tolerance: TimeInterval = 1e-9

    private(set) var now: TimeInterval = 0
    private var pending: [Work] = []
    private var nextOrder = 0

    var pendingCount: Int {
        pending.filter { $0.action != nil }.count
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> any ScheduledWork {
        let item = Work(deadline: now + delay, order: nextOrder, action: work)
        nextOrder += 1
        pending.append(item)
        return item
    }

    func advance(by delta: TimeInterval) {
        advance(to: now + delta)
    }

    func advance(to target: TimeInterval) {
        while let next = pending
            .filter({ $0.action != nil && $0.deadline <= target + Self.tolerance })
            .min(by: { ($0.deadline, $0.order) < ($1.deadline, $1.order) }) {
            now = max(now, next.deadline)
            let action = next.action
            next.action = nil
            action?()
        }
        now = max(now, target)
        pending.removeAll { $0.action == nil }
    }
}

/// Delivers `KeyEvent` values only while a service has started it.
final class FakeKeySource: KeyEventSource {
    private var handler: ((KeyEvent) -> Void)?
    private(set) var startCount = 0

    var isActive: Bool {
        handler != nil
    }

    func start(_ handler: @escaping (KeyEvent) -> Void) {
        self.handler = handler
        startCount += 1
    }

    func stop() {
        handler = nil
    }

    func send(_ event: KeyEvent) {
        handler?(event)
    }
}

/// Mirrors the `KeyboardShortcuts` 2.4.0 rules that matter here: `onKeyDown` and `enable` register a
/// name that has keys, `setShortcut` registers the new keys at once, `disable` and `removeHandler`
/// unregister. A press reaches the handlers only while the name is registered.
final class FakeHotkeyRegistrar: HotkeyRegistrar {
    enum Call: Equatable {
        case enable(KeyboardShortcuts.Name)
        case disable(KeyboardShortcuts.Name)
        case setShortcut(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut?)
    }

    static let packageDefaults: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = {
        var result: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
        for name in ShortcutCaptureSession.managedNames {
            result[name] = name.defaultShortcut
        }
        return result
    }()

    private(set) var shortcuts: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut]
    private var handlers: [KeyboardShortcuts.Name: [() -> Void]] = [:]
    private var registered: Set<KeyboardShortcuts.Name> = []
    private(set) var calls: [Call] = []

    init(shortcuts: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = FakeHotkeyRegistrar.packageDefaults) {
        self.shortcuts = shortcuts
    }

    func onKeyDown(for name: KeyboardShortcuts.Name, handler: @escaping () -> Void) {
        handlers[name, default: []].append(handler)
        if shortcuts[name] != nil { registered.insert(name) }
    }

    func removeHandler(for name: KeyboardShortcuts.Name) {
        handlers[name] = nil
        registered.remove(name)
    }

    func disable(_ name: KeyboardShortcuts.Name) {
        calls.append(.disable(name))
        registered.remove(name)
    }

    func enable(_ name: KeyboardShortcuts.Name) {
        calls.append(.enable(name))
        if shortcuts[name] != nil { registered.insert(name) }
    }

    func isEnabled(_ name: KeyboardShortcuts.Name) -> Bool {
        registered.contains(name) && shortcuts[name] != nil
    }

    func getShortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? {
        shortcuts[name]
    }

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        calls.append(.setShortcut(name, shortcut))
        shortcuts[name] = shortcut
        if shortcut == nil { registered.remove(name) } else { registered.insert(name) }
    }

    func handlerCount(for name: KeyboardShortcuts.Name) -> Int {
        handlers[name]?.count ?? 0
    }

    /// A press of the name's keys, as Carbon would deliver it.
    func fire(_ name: KeyboardShortcuts.Name) {
        guard isEnabled(name) else { return }
        handlers[name]?.forEach { $0() }
    }

    /// A press of `keys`: reaches every enabled name whose current keys are `keys`.
    func fire(keys: KeyboardShortcuts.Shortcut) {
        for (name, shortcut) in shortcuts where shortcut == keys {
            fire(name)
        }
    }
}

/// A `SettingsStorage` on its own suite; the suite is removed when the box goes away (test-plan 7.6).
final class IsolatedSettings {
    let suiteName: String
    let defaults: UserDefaults
    let settings: SettingsStorage

    init(_ label: String = "Shortcuts") {
        suiteName = "\(label).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = SettingsStorage(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension KeyEvent {
    static func key(
        _ keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags = [],
        at timestamp: TimeInterval = 0,
        isRepeat: Bool = false,
        characters: String? = nil
    ) -> KeyEvent {
        .keyDown(
            keyCode: keyCode,
            modifiersRawValue: modifiers.rawValue,
            isRepeat: isRepeat,
            timestamp: timestamp,
            characters: characters
        )
    }

    static func flags(_ keyCode: UInt16, _ rawValue: UInt, at timestamp: TimeInterval = 0) -> KeyEvent {
        .flagsChanged(keyCode: keyCode, flagsRawValue: rawValue, timestamp: timestamp)
    }

    static func flags(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, at timestamp: TimeInterval = 0) -> KeyEvent {
        .flagsChanged(keyCode: keyCode, flagsRawValue: modifiers.rawValue, timestamp: timestamp)
    }
}

enum KeyCode {
    static let a: UInt16 = 0
    static let x: UInt16 = 7
    static let d: UInt16 = 2
    static let i: UInt16 = 34
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let f5: UInt16 = 96
    static let f6: UInt16 = 97
    static let rightShift: UInt16 = 60
    static let leftShift: UInt16 = 56
    static let rightOption: UInt16 = 61
    static let leftOption: UInt16 = 58
    static let leftCommand: UInt16 = 55
    static let leftControl: UInt16 = 59
    static let capsLock: UInt16 = 57
}
