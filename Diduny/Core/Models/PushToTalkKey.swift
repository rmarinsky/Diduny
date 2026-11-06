import AppKit
import Foundation

enum PushToTalkKey: String, Codable, CaseIterable, Identifiable {
    case none
    case capsLock
    case leftShift
    case leftOption
    case leftCommand
    case leftControl
    case rightShift
    case rightOption
    case rightCommand
    case rightControl

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .none:
            String(localized: "Disabled")
        case .capsLock:
            String(localized: "Caps Lock")
        case .leftShift:
            String(localized: "Left Shift")
        case .leftOption:
            String(localized: "Left Option")
        case .leftCommand:
            String(localized: "Left Command")
        case .leftControl:
            String(localized: "Left Control")
        case .rightShift:
            String(localized: "Right Shift")
        case .rightOption:
            String(localized: "Right Option")
        case .rightCommand:
            String(localized: "Right Command")
        case .rightControl:
            String(localized: "Right Control")
        }
    }

    var symbol: String {
        switch self {
        case .none:
            ""
        case .capsLock:
            "⇪"
        case .leftShift:
            "⇧"
        case .leftOption:
            "⌥"
        case .leftCommand:
            "⌘"
        case .leftControl:
            "⌃"
        case .rightShift:
            "⇧"
        case .rightOption:
            "⌥"
        case .rightCommand:
            "⌘"
        case .rightControl:
            "⌃"
        }
    }

    var isOptionOrCommand: Bool {
        switch self {
        case .leftOption, .rightOption, .leftCommand, .rightCommand: true
        default: false
        }
    }

    /// The side-agnostic family of a modifier key; nil for Caps Lock and none.
    var modifierFamily: ModifierFamilies? {
        switch self {
        case .leftShift, .rightShift: .shift
        case .leftControl, .rightControl: .control
        case .leftOption, .rightOption: .option
        case .leftCommand, .rightCommand: .command
        case .none, .capsLock: nil
        }
    }

    /// Keys of the chord's families taken by an active modifier push-to-talk; the in-place gesture
    /// ignores them. With the default ⌥⌘ chord these are the ⌥ and ⌘ keys, as before.
    static func reservedForInplaceTranslation(
        _ shortcuts: [(key: PushToTalkKey, active: Bool)],
        chord: ModifierFamilies = .optionCommand
    ) -> Set<PushToTalkKey> {
        Set(shortcuts.filter { $0.active && $0.key.modifierFamily.map(chord.contains) == true }.map(\.key))
    }

    /// The gesture needs one free key of every family in the chord.
    static func blocksInplaceTranslation(_ reserved: Set<PushToTalkKey>, chord: ModifierFamilies = .optionCommand) -> Bool {
        let bothSides: [(ModifierFamilies, Set<PushToTalkKey>)] = [
            (.option, [.leftOption, .rightOption]),
            (.command, [.leftCommand, .rightCommand]),
            (.control, [.leftControl, .rightControl]),
            (.shift, [.leftShift, .rightShift])
        ]
        return bothSides.contains { family, keys in chord.contains(family) && reserved.isSuperset(of: keys) }
    }

    /// Label for picker display (symbol + name)
    var pickerLabel: String {
        switch self {
        case .none:
            "Disabled"
        default:
            "\(symbol) \(displayName)"
        }
    }
}

struct RecordingCancelShortcut: Codable, Equatable {
    static let defaultShortcut = RecordingCancelShortcut(keyCode: 53, modifiersRawValue: 0, keyLabel: "Esc")
    static let escapeKeyCode: UInt16 = 53
    /// F1 to F20: accepted without a modifier, like Esc.
    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    private static let supportedModifierFlags: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    let keyCode: UInt16
    let modifiersRawValue: UInt
    let keyLabel: String

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    var displayName: String {
        let symbols = modifiers.displaySymbols
        return symbols.isEmpty ? keyLabel : "\(symbols)\(keyLabel)"
    }

    var repeatHint: String {
        "Press \(displayName) again to cancel"
    }

    init(keyCode: UInt16, modifiersRawValue: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiersRawValue = modifiersRawValue
        self.keyLabel = keyLabel.isEmpty ? Self.defaultLabel(for: keyCode) : keyLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiersRawValue = try container.decode(UInt.self, forKey: .modifiersRawValue)
        keyLabel = try container.decodeIfPresent(String.self, forKey: .keyLabel) ?? Self.defaultLabel(for: keyCode)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else { return false }
        guard event.keyCode == keyCode else { return false }

        let normalizedFlags = Self.normalizedModifiers(event.modifierFlags)
        return normalizedFlags.rawValue == modifiersRawValue
    }

    /// A key-down of this key. A key stored without modifiers (Esc, a bare F key) matches whatever
    /// modifiers are held, as the old key-code-53 check did; a chord needs exactly its modifiers.
    func matches(_ event: KeyEvent) -> Bool {
        guard case let .keyDown(eventKeyCode, modifiers, isRepeat, _, _) = event, !isRepeat else { return false }
        guard eventKeyCode == keyCode else { return false }
        guard modifiersRawValue != 0 else { return true }
        return Self.normalizedModifiers(NSEvent.ModifierFlags(rawValue: modifiers)).rawValue == modifiersRawValue
    }

    static func from(event: NSEvent) -> RecordingCancelShortcut {
        make(keyCode: event.keyCode, modifierFlags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
    }

    static func make(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String?) -> RecordingCancelShortcut {
        RecordingCancelShortcut(
            keyCode: keyCode,
            modifiersRawValue: normalizedModifiers(modifierFlags).rawValue,
            keyLabel: keyLabel(keyCode: keyCode, characters: characters)
        )
    }

    private static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(supportedModifierFlags)
    }

    private static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        let defaultLabel = defaultLabel(for: keyCode)
        if defaultLabel != "Key \(keyCode)" {
            return defaultLabel
        }

        guard let chars = characters?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !chars.isEmpty
        else {
            return defaultLabel
        }

        if chars == " " {
            return "Space"
        }
        return chars.uppercased()
    }

    private static func defaultLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 36: "Return"
        case 48: "Tab"
        case 49: "Space"
        case 51: "Delete"
        case 53: "Esc"
        case 122: "F1"
        case 120: "F2"
        case 99: "F3"
        case 118: "F4"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 100: "F8"
        case 101: "F9"
        case 109: "F10"
        case 103: "F11"
        case 111: "F12"
        case 105: "F13"
        case 107: "F14"
        case 113: "F15"
        case 106: "F16"
        case 64: "F17"
        case 79: "F18"
        case 80: "F19"
        case 90: "F20"
        case 123: "Left Arrow"
        case 124: "Right Arrow"
        case 125: "Down Arrow"
        case 126: "Up Arrow"
        default: "Key \(keyCode)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiersRawValue
        case keyLabel
    }
}

private extension NSEvent.ModifierFlags {
    var displaySymbols: String {
        var result = ""
        if contains(.command) { result += "⌘" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.control) { result += "⌃" }
        return result
    }
}
