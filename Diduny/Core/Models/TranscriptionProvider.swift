import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case cloud
    case local

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .cloud: String(localized: "Cloud")
        case .local: String(localized: "Local (Whisper)")
        }
    }
}
