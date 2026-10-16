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
            String(localized: "Network error: \(error.localizedDescription)")
        case let .apiError(message):
            String(localized: "API error: \(message)")
        case .invalidResponse:
            String(localized: "Invalid response from server")
        case .emptyTranscription:
            String(localized: "No speech detected")
        case let .cloudConnectionFailed(reason):
            String(localized: "Cloud connection failed: \(reason)")
        case .invalidURL:
            String(localized: "Invalid API URL")
        case let .usageLimitExceeded(usedHours, limitHours):
            String(
                localized: "Cloud usage limit reached (\(String(format: "%.1f", usedHours))h / \(String(format: "%.0f", limitHours))h). Using local model."
            )
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
            String(localized: "No audio input device found")
        case .permissionDenied:
            String(localized: "Microphone permission denied. Please enable in System Settings.")
        case let .recordingFailed(reason):
            String(localized: "Recording failed: \(reason)")
        case .deviceNotFound:
            String(localized: "Selected audio device not found")
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
            String(localized: "Real-time connection failed: \(reason)")
        case let .webSocketError(error):
            String(localized: "WebSocket error: \(error.localizedDescription)")
        case let .usageLimitExceeded(usedHours, limitHours):
            String(
                localized: "Cloud usage limit reached (\(String(format: "%.1f", usedHours))h / \(String(format: "%.0f", limitHours))h). Using local model."
            )
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
            String(localized: "Failed to save to Keychain")
        case .readFailed:
            String(localized: "Failed to read from Keychain")
        case .deleteFailed:
            String(localized: "Failed to delete from Keychain")
        }
    }
}
