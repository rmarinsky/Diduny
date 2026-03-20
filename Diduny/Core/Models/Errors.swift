import Foundation

enum TranscriptionError: LocalizedError {
    case networkError(Error)
    case apiError(String)
    case invalidResponse
    case emptyTranscription
    case cloudConnectionFailed(String)
    case invalidURL
    case usageLimitExceeded(usedHours: Double, limitHours: Double)

    var errorDescription: String? {
        switch self {
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .apiError(message):
            "API error: \(message)"
        case .invalidResponse:
            "Invalid response from server"
        case .emptyTranscription:
            "No speech detected"
        case let .cloudConnectionFailed(reason):
            "Cloud connection failed: \(reason)"
        case .invalidURL:
            "Invalid API URL"
        case let .usageLimitExceeded(usedHours, limitHours):
            "Cloud usage limit reached (\(String(format: "%.1f", usedHours))h / \(String(format: "%.0f", limitHours))h). Using local model."
        }
    }
}

extension TranscriptionError {
    var isUsageLimitExceeded: Bool {
        guard case .usageLimitExceeded = self else { return false }
        return true
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

enum RealtimeTranscriptionError: LocalizedError {
    case connectionFailed(String)
    case webSocketError(Error)
    case usageLimitExceeded(usedHours: Double, limitHours: Double)

    var errorDescription: String? {
        switch self {
        case let .connectionFailed(reason):
            "Real-time connection failed: \(reason)"
        case let .webSocketError(error):
            "WebSocket error: \(error.localizedDescription)"
        case let .usageLimitExceeded(usedHours, limitHours):
            "Cloud usage limit reached (\(String(format: "%.1f", usedHours))h / \(String(format: "%.0f", limitHours))h). Using local model."
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
