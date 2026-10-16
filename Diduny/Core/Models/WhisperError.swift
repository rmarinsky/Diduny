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
            String(localized: "Failed to load Whisper model")
        case .contextNotInitialized:
            String(localized: "Whisper context not initialized")
        case .transcriptionFailed:
            String(localized: "Local transcription failed")
        case .audioConversionFailed:
            String(localized: "Failed to convert audio for Whisper")
        case .modelNotFound:
            String(localized: "No Whisper model downloaded. Please download one in Settings.")
        case let .downloadFailed(reason):
            String(localized: "Model download failed: \(reason)")
        case .modelDoesNotSupportTranslation:
            String(
                localized: "Selected model is English-only and cannot translate. Please select a multilingual model."
            )
        case let .unsupportedTranslationTarget(target):
            String(
                localized: "Local Whisper can translate to English only. Switch Translation Provider to Cloud or choose English. Target: \(target.uppercased())."
            )
        }
    }
}
