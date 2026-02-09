import Foundation

// MARK: - Realtime Token

struct RealtimeToken: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let speaker: String?
    let startMs: Int
    let endMs: Int

    init(text: String, isFinal: Bool, speaker: String? = nil, startMs: Int = 0, endMs: Int = 0) {
        self.id = UUID()
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
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

// MARK: - Soniox RT API Response

struct SonioxRealtimeResponse: Decodable {
    let tokens: [SonioxRealtimeToken]?
    let finished: Bool?

    struct SonioxRealtimeToken: Decodable {
        let text: String
        let is_final: Bool
        let speaker: String?
        let start_ms: Int?
        let end_ms: Int?
    }
}
