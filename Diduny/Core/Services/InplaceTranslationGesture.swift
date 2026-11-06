import Foundation

/// Pure state machine for the in-place modifier gesture: tap a modifier chord (default ⌥⌘) 2x or 3x.
///
/// Fed with modifier-state changes and non-modifier key-downs; returns `true` when the last tap has
/// been released. A tap is every chord key down, then all up. Partial states (only part of the chord
/// down) are the normal ramp up/down of a tap and are ignored. Each press must start less than
/// `threshold` after the previous press started; for 2x this is today's rule.
struct InplaceTranslationGesture {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let option = Modifiers(rawValue: 1 << 0)
        static let command = Modifiers(rawValue: 1 << 1)
        /// A modifier outside the chord, or a key push-to-talk owns: cancels the gesture.
        static let other = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
        static let shift = Modifiers(rawValue: 1 << 4)

        static let optionCommand: Modifiers = [.option, .command]

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(_ families: ModifierFamilies) {
            var result: Modifiers = []
            if families.contains(.option) { result.insert(.option) }
            if families.contains(.command) { result.insert(.command) }
            if families.contains(.control) { result.insert(.control) }
            if families.contains(.shift) { result.insert(.shift) }
            self = result
        }
    }

    enum Event: Equatable {
        case modifiersChanged(Modifiers, at: TimeInterval)
        case keyDown
    }

    private enum Phase: Equatable {
        case idle
        case down(count: Int, pressedAt: TimeInterval)
        case up(count: Int, pressedAt: TimeInterval)
    }

    /// Same interval `HotkeyService` uses for multi-press hotkeys (press to press).
    static let defaultThreshold: TimeInterval = 0.35

    let threshold: TimeInterval
    let chord: Modifiers
    /// 2 or 3: 1x on a modifier chord would fire on any lone press (ADR-0012 D8), so 1 reads as 2.
    let pressCount: Int
    private var phase: Phase = .idle

    init(threshold: TimeInterval = Self.defaultThreshold, chord: Modifiers = .optionCommand, pressCount: Int = 2) {
        self.threshold = threshold
        self.chord = chord
        self.pressCount = min(max(pressCount, 2), 3)
    }

    mutating func reset() {
        phase = .idle
    }

    /// Returns `true` exactly when the last tap completes.
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
        if modifiers.contains(.other) || !modifiers.isSubset(of: chord) {
            phase = .idle
            return false
        }

        let chordDown = modifiers == chord
        let allUp = modifiers.isEmpty

        switch phase {
        case .idle:
            if chordDown { phase = .down(count: 1, pressedAt: time) }
        case let .down(count, pressedAt):
            guard allUp else { break }
            if count >= pressCount {
                phase = .idle
                return true
            }
            phase = .up(count: count, pressedAt: pressedAt)
        case let .up(count, pressedAt):
            if time - pressedAt >= threshold {
                // Too slow: this press starts a new gesture instead.
                phase = chordDown ? .down(count: 1, pressedAt: time) : .idle
            } else if chordDown {
                phase = .down(count: count + 1, pressedAt: time)
            }
        }
        return false
    }
}
