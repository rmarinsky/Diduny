import Foundation

/// Pure state machine for the "double-tap ⌥⌘" gesture.
///
/// Fed with modifier-state changes and non-modifier key-downs; returns `true`
/// when the second tap has been released and the gesture is complete.
/// A tap is ⌥ and ⌘ both down, then both up. Partial states (only one of the
/// two down) are the normal ramp up/down of a tap and are ignored.
struct InplaceTranslationGesture {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let option = Modifiers(rawValue: 1 << 0)
        static let command = Modifiers(rawValue: 1 << 1)
        /// Any other modifier (⇧ or ⌃): cancels the gesture.
        static let other = Modifiers(rawValue: 1 << 2)

        static let optionCommand: Modifiers = [.option, .command]
    }

    enum Event: Equatable {
        case modifiersChanged(Modifiers, at: TimeInterval)
        case keyDown
    }

    private enum Phase: Equatable {
        case idle
        case firstDown(pressedAt: TimeInterval)
        case firstUp(pressedAt: TimeInterval)
        case secondDown(pressedAt: TimeInterval)
    }

    /// Same interval `HotkeyService` uses for multi-press hotkeys (press to press).
    static let defaultThreshold: TimeInterval = 0.35

    let threshold: TimeInterval
    private var phase: Phase = .idle

    init(threshold: TimeInterval = Self.defaultThreshold) {
        self.threshold = threshold
    }

    mutating func reset() {
        phase = .idle
    }

    /// Returns `true` exactly when the double tap completes.
    mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .keyDown:
            phase = .idle
            return false
        case let .modifiersChanged(modifiers, time):
            return handleModifiers(modifiers, at: time)
        }
    }

    private mutating func handleModifiers(_ modifiers: Modifiers, at time: TimeInterval) -> Bool {
        if modifiers.contains(.other) {
            phase = .idle
            return false
        }

        let bothDown = modifiers == .optionCommand
        let allUp = modifiers.isEmpty

        switch phase {
        case .idle:
            if bothDown { phase = .firstDown(pressedAt: time) }
        case .firstDown(let pressedAt):
            if allUp { phase = .firstUp(pressedAt: pressedAt) }
        case .firstUp(let pressedAt):
            if time - pressedAt >= threshold {
                // Too slow: this press starts a new gesture instead.
                phase = bothDown ? .firstDown(pressedAt: time) : .idle
            } else if bothDown {
                phase = .secondDown(pressedAt: pressedAt)
            }
        case .secondDown:
            if allUp {
                phase = .idle
                return true
            }
        }
        return false
    }
}
