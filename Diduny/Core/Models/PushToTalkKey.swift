import Foundation

enum PushToTalkKey: String, Codable, CaseIterable, Identifiable {
    case none
    case capsLock
    case rightShift
    case rightOption
    case rightCommand

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
