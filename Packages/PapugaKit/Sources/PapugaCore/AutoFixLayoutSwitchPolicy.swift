import Foundation

enum AutoFixLayoutSwitchPolicy: String, Codable, CaseIterable {
    case alwaysSwitchToReplacementLayout
    case keepCurrentLayout
    case adaptive

    var title: String {
        switch self {
        case .alwaysSwitchToReplacementLayout:
            return "Завжди переходити на мову заміни"
        case .keepCurrentLayout:
            return "Залишати поточну розкладку"
        case .adaptive:
            return "Адаптивно"
        }
    }
}

struct AutoFixReplacementDirection: Equatable {
    let fromLayoutID: String
    let targetLayoutID: String
    var count: Int
}
