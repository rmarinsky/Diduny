import Foundation

enum WhisperError: LocalizedError {
    case modelLoadFailed
    case contextNotInitialized
    case transcriptionFailed
    case audioConversionFailed
    case modelNotFound
    case downloadFailed(String)
    case modelDoesNotSupportTranslation

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            "Failed to load Whisper model"
        case .contextNotInitialized:
            "Whisper context not initialized"
        case .transcriptionFailed:
            "Local transcription failed"
        case .audioConversionFailed:
            "Failed to convert audio for Whisper"
        case .modelNotFound:
            "No Whisper model downloaded. Please download one in Settings."
        case let .downloadFailed(reason):
            "Model download failed: \(reason)"
        case .modelDoesNotSupportTranslation:
            "Selected model is English-only and cannot translate. Please select a multilingual model."
        }
    }
}
