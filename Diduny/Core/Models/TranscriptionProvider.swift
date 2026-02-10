import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case soniox = "soniox"
    case whisperLocal = "whisper_local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soniox: "Soniox (Cloud)"
        case .whisperLocal: "Whisper (Local)"
        }
    }
}
