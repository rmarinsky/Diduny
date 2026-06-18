import Foundation

enum WhisperError: LocalizedError {
    case modelLoadFailed
    case contextNotInitialized
    case transcriptionFailed
    case audioConversionFailed
    case modelNotFound
    case downloadFailed(String)
    case modelDoesNotSupportTranslation
    case unsupportedTranslationTarget(String)

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
        case let .unsupportedTranslationTarget(target):
            "Local Whisper can translate to English only. Switch Translation Provider to Cloud or choose English. Target: \(target.uppercased())."
        }
    }
}
