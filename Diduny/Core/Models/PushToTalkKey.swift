import AppKit
import Foundation

enum PushToTalkKey: String, Codable, CaseIterable, Identifiable {
    case none
    case capsLock
    case rightShift
    case rightOption
    case rightCommand
    case rightControl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            "Disabled"
        case .capsLock:
            "Caps Lock"
        case .rightShift:
            "Right Shift"
        case .rightOption:
            "Right Option"
        case .rightCommand:
            "Right Command"
        case .rightControl:
            "Right Control"
        }
    }

    var symbol: String {
        switch self {
        case .none:
            ""
        case .capsLock:
            "⇪"
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

    static func from(event: NSEvent) -> RecordingCancelShortcut {
        RecordingCancelShortcut(
            keyCode: event.keyCode,
            modifiersRawValue: normalizedModifiers(event.modifierFlags).rawValue,
            keyLabel: keyLabel(for: event)
        )
    }

    private static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(supportedModifierFlags)
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let defaultLabel = defaultLabel(for: event.keyCode)
        if defaultLabel != "Key \(event.keyCode)" {
            return defaultLabel
        }

        guard let chars = event.charactersIgnoringModifiers?
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
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 123: return "Left Arrow"
        case 124: return "Right Arrow"
        case 125: return "Down Arrow"
        case 126: return "Up Arrow"
        default: return "Key \(keyCode)"
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
