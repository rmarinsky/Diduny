import Foundation

enum PushToTalkKey: String, Codable, CaseIterable {
    case none
    case capsLock
    case rightShift
    case rightOption

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
        }
    }
}
