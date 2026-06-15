import Foundation

enum RecordingFeedbackSurface: String, CaseIterable, Identifiable {
    case notch
    case compactPanel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            "Dynamic Notch"
        case .compactPanel:
            "Compact Panel"
        }
    }
}
