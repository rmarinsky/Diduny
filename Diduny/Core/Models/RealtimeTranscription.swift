import Foundation

// MARK: - Realtime Token

struct RealtimeToken: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let speaker: String?
    let startMs: Int
    let endMs: Int
    let language: String?
    let sourceLanguage: String?
    let translationStatus: String?

    init(
        text: String,
        isFinal: Bool,
        speaker: String? = nil,
        startMs: Int = 0,
        endMs: Int = 0,
        language: String? = nil,
        sourceLanguage: String? = nil,
        translationStatus: String? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
        self.language = language
        self.sourceLanguage = sourceLanguage
        self.translationStatus = translationStatus
    }
}

// MARK: - Transcript Segment

struct TranscriptSegment: Identifiable {
    let id: UUID
    var speaker: String?
    var tokens: [RealtimeToken]
    var startMs: Int

    init(speaker: String? = nil, tokens: [RealtimeToken] = [], startMs: Int = 0) {
        self.id = UUID()
        self.speaker = speaker
        self.tokens = tokens
        self.startMs = startMs
    }

    var text: String {
        tokens.map(\.text).joined()
    }

    var isFinal: Bool {
        tokens.allSatisfy(\.isFinal)
    }

    var timestamp: String {
        let totalSeconds = startMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Connection Status

enum RealtimeConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
}

// MARK: - Realtime Config

struct RealtimeAudioConfig: Equatable {
    let audioFormat: String
    let sampleRate: Int
    let numChannels: Int

    static let defaultPCM16kMono = RealtimeAudioConfig(
        audioFormat: "s16le",
        sampleRate: 16000,
        numChannels: 1
    )
}

struct RealtimeTranslationConfig: Equatable {
    enum Mode: Equatable {
        case twoWay(languageA: String, languageB: String)
        case oneWay(sourceLanguage: String, targetLanguage: String)
    }

    let mode: Mode
}

// MARK: - Soniox RT API Response

struct SonioxRealtimeResponse: Decodable {
    let tokens: [SonioxRealtimeToken]?
    let finished: Bool?
    let errorCode: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }

    struct SonioxRealtimeToken: Decodable {
        let text: String
        let isFinal: Bool
        let speaker: String?
        let startMs: Int?
        let endMs: Int?
        let language: String?
        let sourceLanguage: String?
        let translationStatus: String?

        enum CodingKeys: String, CodingKey {
            case text, speaker, language
            case isFinal = "is_final"
            case startMs = "start_ms"
            case endMs = "end_ms"
            case sourceLanguage = "source_language"
            case translationStatus = "translation_status"
        }
    }
}
