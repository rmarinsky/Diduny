import Foundation

enum TranscriptionError: LocalizedError {
    case noAPIKey
    case networkError(Error)
    case apiError(String)
    case invalidResponse
    case emptyTranscription
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "Please add your Soniox API key in Settings"
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .apiError(message):
            "API error: \(message)"
        case .invalidResponse:
            "Invalid response from server"
        case .emptyTranscription:
            "No speech detected"
        case .invalidURL:
            "Invalid API URL"
        }
    }
}

enum AudioError: LocalizedError {
    case noInputDevice
    case permissionDenied
    case recordingFailed(String)
    case deviceNotFound

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No audio input device found"
        case .permissionDenied:
            "Microphone permission denied. Please enable in System Settings."
        case let .recordingFailed(reason):
            "Recording failed: \(reason)"
        case .deviceNotFound:
            "Selected audio device not found"
        }
    }
}

enum KeychainError: LocalizedError {
    case saveFailed
    case readFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed:
            "Failed to save to Keychain"
        case .readFailed:
            "Failed to read from Keychain"
        case .deleteFailed:
            "Failed to delete from Keychain"
        }
    }
}
