import Foundation

enum ReplacementHistoryRetention: String, CaseIterable {
    case oneWeek
    case oneMonth
    case threeMonths
    case forever

    var title: String {
        switch self {
        case .oneWeek: return "1 тиждень"
        case .oneMonth: return "1 місяць"
        case .threeMonths: return "3 місяці"
        case .forever: return "Завжди"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .oneWeek: return 7 * 24 * 60 * 60
        case .oneMonth: return 30 * 24 * 60 * 60
        case .threeMonths: return 90 * 24 * 60 * 60
        case .forever: return nil
        }
    }
}
