import Foundation

enum RecordingFeedbackSurface: String, CaseIterable, Identifiable {
    case notch
    case compactPanel

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .notch:
            String(localized: "Dynamic Notch")
        case .compactPanel:
            String(localized: "Floating modal")
        }
    }
}
