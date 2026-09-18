import Foundation

// MARK: - TTS Voice

/// A voice available from the 60db TTS API (GET /voices).
struct TTSVoice: Identifiable, Codable, Equatable, Hashable {
    struct Labels: Codable, Equatable, Hashable {
        let language: String?
        let languageName: String?
        let gender: String?
        let accent: String?

        enum CodingKeys: String, CodingKey {
            case language
            case languageName = "language_name"
            case gender
            case accent
        }
    }

    let voiceId: UUID
    let name: String
    let labels: Labels?
    let descriptionText: String?
    let categories: [String]?

    var id: UUID { voiceId }

    /// Short descriptor shown in pickers, e.g. "English · female".
    var subtitle: String {
        [labels?.languageName, labels?.gender]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case name
        case labels
        case descriptionText = "description"
        case categories
    }
}

// MARK: - Model Tier

/// 60db voice catalog tier: `quality` (professional voices) or `fast` (cloned voices).
enum TTSModelTier: String, CaseIterable, Identifiable {
    case quality
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quality: "Quality"
        case .fast: "Fast"
        }
    }
}

// MARK: - API Response Models

struct TTSVoicesResponse: Decodable {
    let success: Bool
    let message: String?
    let data: [TTSVoice]
}

struct TTSSynthesisResponse: Decodable {
    let success: Bool
    let message: String?
    let audioBase64: String
    let sampleRate: Int
    let durationSeconds: Double?
    let encoding: String?
    let outputFormat: String?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case audioBase64 = "audio_base64"
        case sampleRate = "sample_rate"
        case durationSeconds = "duration_seconds"
        case encoding
        case outputFormat = "output_format"
    }
}

// MARK: - Errors

enum TTSError: LocalizedError, Equatable {
    case noAPIKey
    case invalidURL
    case invalidResponse
    case apiError(status: Int, message: String?)
    case noAudioData
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "No 60db API key configured. Add one in Settings → Speech."
        case .invalidURL:
            "The 60db service URL is invalid."
        case .invalidResponse:
            "The 60db service returned an unexpected response."
        case let .apiError(status, message):
            if let message, !message.isEmpty {
                "60db request failed (\(status)): \(message)"
            } else {
                "60db request failed with status \(status)."
            }
        case .noAudioData:
            "The 60db service returned no audio for this text."
        case let .playbackFailed(reason):
            "Failed to play synthesized audio: \(reason)"
        }
    }
}
