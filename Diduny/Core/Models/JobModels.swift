import Foundation

// MARK: - Async Jobs API Models

struct JobSubmission: Decodable {
    let jobId: String
    let status: String
    let createdAt: String
}

struct JobStatusResponse: Decodable {
    let jobId: String
    let status: String
    let progress: Int?
    let createdAt: String
    let updatedAt: String
    let result: JobTranscriptionResult?
    let error: String?
}

struct JobTranscriptionResult: Decodable {
    let text: String
    let tokens: [JobTranscriptionToken]

    private enum CodingKeys: String, CodingKey {
        case text
        case transcript
        case tokens
        case words
        case segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = (try? container.decode([JobTranscriptionToken].self, forKey: .tokens))
            ?? (try? container.decode([JobTranscriptionToken].self, forKey: .words))
            ?? (try? container.decode([JobTranscriptionToken].self, forKey: .segments))
            ?? []

        text = container.decodeStringIfPresent(forKeys: [.text, .transcript])
            ?? tokens.map(\.text).joined()
    }

    func outputText(preferSpeakerDiarization: Bool) -> String {
        guard preferSpeakerDiarization else {
            return text
        }

        return DiarizedTranscriptFormatter.format(tokens: tokens, fallbackText: text)
    }
}

struct JobTranscriptionToken: Decodable, Equatable {
    let text: String
    let startMs: Int?
    let endMs: Int?
    let speaker: String?
    let language: String?
    let confidence: Double?

    private enum CodingKeys: String, CodingKey {
        case text
        case token
        case word
        case startMsSnake = "start_ms"
        case startMsCamel = "startMs"
        case startSecondsSnake = "start_seconds"
        case startSecondsCamel = "startSeconds"
        case start
        case endMsSnake = "end_ms"
        case endMsCamel = "endMs"
        case endSecondsSnake = "end_seconds"
        case endSecondsCamel = "endSeconds"
        case end
        case speaker
        case speakerId = "speaker_id"
        case speakerIndex = "speaker_index"
        case language
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        text = container.decodeRawStringIfPresent(forKeys: [.text, .token, .word]) ?? ""
        startMs = container.decodeMillisecondsIfPresent(
            millisecondKeys: [.startMsSnake, .startMsCamel],
            secondKeys: [.startSecondsSnake, .startSecondsCamel, .start]
        )
        endMs = container.decodeMillisecondsIfPresent(
            millisecondKeys: [.endMsSnake, .endMsCamel],
            secondKeys: [.endSecondsSnake, .endSecondsCamel, .end]
        )
        speaker = container.decodeStringIfPresent(forKeys: [.speaker, .speakerId, .speakerIndex])
        language = container.decodeStringIfPresent(forKeys: [.language])
        confidence = container.decodeDoubleIfPresent(forKeys: [.confidence])
    }
}

struct JobResult {
    let text: String
    let tokens: [JobTranscriptionToken]

    init(text: String, tokens: [JobTranscriptionToken] = []) {
        self.text = text
        self.tokens = tokens
    }

    func outputText(preferSpeakerDiarization: Bool) -> String {
        guard preferSpeakerDiarization else {
            return text
        }

        return DiarizedTranscriptFormatter.format(tokens: tokens, fallbackText: text)
    }
}

enum JobStatus: String {
    case queued, uploading, processing, finalizing, completed, error
}

enum DiarizedTranscriptFormatter {
    private struct Segment {
        var speaker: String?
        var startMs: Int
        var endMs: Int?
        var text: String
    }

    private static let sameSpeakerGapThresholdMs = 2_500

    static func format(tokens: [JobTranscriptionToken], fallbackText: String) -> String {
        guard tokens.contains(where: { $0.speaker != nil || $0.startMs != nil || $0.endMs != nil }) else {
            return fallbackText
        }

        var segments: [Segment] = []

        for token in tokens {
            guard !token.text.isEmpty else { continue }

            let visibleText = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if visibleText.isEmpty {
                appendWhitespace(token.text, endMs: token.endMs, to: &segments)
                continue
            }

            let speaker = normalizedSpeaker(token.speaker)
            let startMs = token.startMs ?? segments.last?.endMs ?? segments.last?.startMs ?? 0
            let endMs = token.endMs ?? startMs

            if shouldStartNewSegment(speaker: speaker, startMs: startMs, previous: segments.last) {
                segments.append(Segment(speaker: speaker, startMs: startMs, endMs: endMs, text: token.text))
            } else {
                segments[segments.count - 1].text = appendedText(segments[segments.count - 1].text, token.text)
                segments[segments.count - 1].endMs = max(segments[segments.count - 1].endMs ?? endMs, endMs)
            }
        }

        let formatted = segments
            .map { segment -> String? in
                let text = cleanedSegmentText(segment.text)
                guard !text.isEmpty else { return nil }
                return "[\(timestamp(for: segment.startMs))] \(speakerLabel(segment.speaker)): \(text)"
            }
            .compactMap { $0 }
            .joined(separator: "\n\n")

        return formatted.isEmpty ? fallbackText : formatted
    }

    private static func appendWhitespace(_ whitespace: String, endMs: Int?, to segments: inout [Segment]) {
        guard !segments.isEmpty else { return }
        segments[segments.count - 1].text += whitespace
        if let endMs {
            segments[segments.count - 1].endMs = max(segments[segments.count - 1].endMs ?? endMs, endMs)
        }
    }

    private static func shouldStartNewSegment(speaker: String?, startMs: Int, previous: Segment?) -> Bool {
        guard let previous else { return true }
        guard previous.speaker == speaker else { return true }
        guard let previousEndMs = previous.endMs else { return false }
        return startMs - previousEndMs > sameSpeakerGapThresholdMs
    }

    private static func normalizedSpeaker(_ speaker: String?) -> String? {
        guard let speaker else { return nil }
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func speakerLabel(_ speaker: String?) -> String {
        guard let speaker else { return "Unknown" }
        if speaker.range(of: "speaker", options: [.caseInsensitive, .anchored]) != nil {
            return speaker
        }
        return "Speaker \(speaker)"
    }

    private static func timestamp(for milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func cleanedSegmentText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendedText(_ current: String, _ next: String) -> String {
        guard shouldInsertSpaceBetween(current, next) else {
            return current + next
        }
        return current + " " + next
    }

    private static func shouldInsertSpaceBetween(_ current: String, _ next: String) -> Bool {
        guard let last = current.unicodeScalars.last,
              let first = next.unicodeScalars.first
        else { return false }

        if CharacterSet.whitespacesAndNewlines.contains(last) ||
            CharacterSet.whitespacesAndNewlines.contains(first) {
            return false
        }

        if CharacterSet(charactersIn: ".,!?;:%)]}").contains(first) {
            return false
        }

        if CharacterSet(charactersIn: "([{$").contains(last) {
            return false
        }

        return true
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

            if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
                return value.rounded() == value ? String(Int(value)) : String(value)
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

            if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
                return value.rounded() == value ? String(Int(value)) : String(value)
            }
        }

        return nil
    }

    func decodeMillisecondsIfPresent(millisecondKeys: [Key], secondKeys: [Key]) -> Int? {
        for key in millisecondKeys {
            if let value = decodeNumericValueIfPresent(forKey: key) {
                return Int(value.rounded())
            }
        }

        for key in secondKeys {
            if let value = decodeNumericValueIfPresent(forKey: key) {
                return Int((value * 1000).rounded())
            }
        }

        return nil
    }

    func decodeDoubleIfPresent(forKeys keys: [Key]) -> Double? {
        for key in keys {
            if let value = decodeNumericValueIfPresent(forKey: key) {
                return value
            }
        }

        return nil
    }

    private func decodeNumericValueIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }

        if let value = try? decodeIfPresent(String.self, forKey: key),
           let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           number.isFinite
        {
            return number
        }

        return nil
    }
}
