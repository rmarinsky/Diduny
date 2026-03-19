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

enum RealtimeSegmentBoundary {
    case endpoint
    case finalize
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

// MARK: - RT API Response

struct RealtimeResponse: Decodable {
    let tokens: [RealtimeResponseToken]?
    let finished: Bool?
    let errorCode: String?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case tokens
        case words
        case finished
        case isFinished = "is_finished"
        case errorCode = "error_code"
        case errorCodeCamel = "errorCode"
        case errorMessage = "error_message"
        case errorMessageCamel = "errorMessage"
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        tokens = (try? container.decode([RealtimeResponseToken].self, forKey: .tokens))
            ?? (try? container.decode([RealtimeResponseToken].self, forKey: .words))
        finished = container.decodeBoolIfPresent(forKeys: [.finished, .isFinished])
        errorCode = container.decodeStringIfPresent(forKeys: [.errorCode, .errorCodeCamel])
        errorMessage = container.decodeStringIfPresent(forKeys: [.errorMessage, .errorMessageCamel, .message])
    }

    struct RealtimeResponseToken: Decodable {
        let text: String
        let isFinal: Bool
        let speaker: String?
        let startMs: Int?
        let endMs: Int?
        let language: String?
        let sourceLanguage: String?
        let translationStatus: String?

        private enum CodingKeys: String, CodingKey {
            case text
            case token
            case word
            case isFinalSnake = "is_final"
            case isFinalCamel = "isFinal"
            case final
            case speaker
            case speakerId = "speaker_id"
            case speakerIndex = "speaker_index"
            case startMsSnake = "start_ms"
            case startMsCamel = "startMs"
            case endMsSnake = "end_ms"
            case endMsCamel = "endMs"
            case language
            case sourceLanguageSnake = "source_language"
            case sourceLanguageCamel = "sourceLanguage"
            case translationStatusSnake = "translation_status"
            case translationStatusCamel = "translationStatus"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            // Keep token spacing exactly as provided by API (space/newline tokens are meaningful).
            text = container.decodeRawStringIfPresent(forKeys: [.text, .token, .word]) ?? ""
            isFinal = container.decodeBoolIfPresent(forKeys: [.isFinalSnake, .isFinalCamel, .final]) ?? false
            speaker = container.decodeStringIfPresent(forKeys: [.speaker, .speakerId, .speakerIndex])
            startMs = container.decodeIntIfPresent(forKeys: [.startMsSnake, .startMsCamel])
            endMs = container.decodeIntIfPresent(forKeys: [.endMsSnake, .endMsCamel])
            language = container.decodeStringIfPresent(forKeys: [.language])
            sourceLanguage = container.decodeStringIfPresent(forKeys: [.sourceLanguageSnake, .sourceLanguageCamel])
            translationStatus = container.decodeStringIfPresent(
                forKeys: [.translationStatusSnake, .translationStatusCamel]
            )
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeRawStringIfPresent(forKeys keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                return value
            }

            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }

            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                if value.isFinite {
                    return value.rounded() == value ? String(Int(value)) : String(value)
                }
            }

            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value ? "true" : "false"
            }
        }

        return nil
    }

    func decodeStringIfPresent(forKeys keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }

            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }

            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                if value.isFinite {
                    return value.rounded() == value ? String(Int(value)) : String(value)
                }
            }

            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value ? "true" : "false"
            }
        }

        return nil
    }

    func decodeBoolIfPresent(forKeys keys: [Key]) -> Bool? {
        for key in keys {
            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value
            }

            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value != 0
            }

            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value != 0
            }

            if let value = try? decodeIfPresent(String.self, forKey: key) {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "t", "yes", "y", "final":
                    return true
                case "0", "false", "f", "no", "n":
                    return false
                default:
                    continue
                }
            }
        }

        return nil
    }

    func decodeIntIfPresent(forKeys keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }

            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                if value.isFinite {
                    return Int(value.rounded())
                }
            }

            if let value = try? decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let intValue = Int(trimmed) {
                    return intValue
                }
                if let doubleValue = Double(trimmed), doubleValue.isFinite {
                    return Int(doubleValue.rounded())
                }
            }
        }

        return nil
    }
}
