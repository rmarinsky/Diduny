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

    private init() {}

    func activate(onTrigger: @escaping () -> Void) {
        guard SettingsStorage.shared.forceSubmitEnabled else {
            deactivate()
            return
        }
        isArmed = false
        self.onTrigger = onTrigger
        guard !isActive else { return }
        isActive = true
        KeyboardShortcuts.removeHandler(for: .forceSubmit)
        KeyboardShortcuts.onKeyDown(for: .forceSubmit) { [weak self] in
            Task { @MainActor in self?.trigger() }
        }
    }

    /// Unregisters the hotkey. Keeps the armed flag so the stop pipeline can still submit after paste.
    func deactivate() {
        isActive = false
        onTrigger = nil
        KeyboardShortcuts.removeHandler(for: .forceSubmit)
        KeyboardShortcuts.disable(.forceSubmit)
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
        guard isActive, !isArmed else { return }
        isArmed = true
        onTrigger?()
    }
}
