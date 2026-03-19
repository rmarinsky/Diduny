import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case cloud = "cloud"
    case local = "local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloud: "Cloud"
        case .local: "Local (Whisper)"
        }
    }
}
