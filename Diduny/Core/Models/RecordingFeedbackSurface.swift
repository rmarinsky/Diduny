import Foundation

enum RecordingFeedbackSurface: String, CaseIterable, Identifiable {
    case notch
    case compactPanel

    var id: String {
        rawValue
    }
}
