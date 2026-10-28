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
    let providerSegments: [JobTranscriptionToken]?
    let insertsSpacesBetweenTokens: Bool

    private enum CodingKeys: String, CodingKey {
        case text
        case transcript
        case tokens
        case words
        case segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try? container.decode([JobTranscriptionToken].self, forKey: .segments),
           decoded.contains(where: { $0.startMs != nil })
        {
            providerSegments = decoded
        } else {
            providerSegments = nil
        }
        if let decoded = try? container.decode([JobTranscriptionToken].self, forKey: .tokens) {
            tokens = decoded
            insertsSpacesBetweenTokens = false
        } else if let decoded = try? container.decode([JobTranscriptionToken].self, forKey: .words) {
            tokens = decoded
            insertsSpacesBetweenTokens = true
        } else if let decoded = providerSegments {
            tokens = decoded
            insertsSpacesBetweenTokens = false
        } else {
            tokens = []
            insertsSpacesBetweenTokens = false
        }

        text = container.decodeStringIfPresent(forKeys: [.text, .transcript])
            ?? tokens.map(\.text).joined()
    }

    func outputText(preferSpeakerDiarization: Bool) -> String {
        guard preferSpeakerDiarization else {
            return text
        }

        return DiarizedTranscriptFormatter.format(
            tokens: providerSegments ?? tokens,
            fallbackText: text,
            insertsSpacesBetweenTokens: insertsSpacesBetweenTokens
        )
    }

    func generatedTranscript(preferSpeakerDiarization: Bool) -> GeneratedTranscript {
        GeneratedTranscript(
            sourceText: text,
            tokens: tokens,
            providerSegments: providerSegments,
            insertsSpacesBetweenTokens: insertsSpacesBetweenTokens,
            preferSpeakerDiarization: preferSpeakerDiarization
        )
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
    let providerSegments: [JobTranscriptionToken]?
    let insertsSpacesBetweenTokens: Bool

    init(
        text: String,
        tokens: [JobTranscriptionToken] = [],
        providerSegments: [JobTranscriptionToken]? = nil,
        insertsSpacesBetweenTokens: Bool = false
    ) {
        self.text = text
        self.tokens = tokens
        self.providerSegments = providerSegments
        self.insertsSpacesBetweenTokens = insertsSpacesBetweenTokens
    }

    func outputText(preferSpeakerDiarization: Bool) -> String {
        guard preferSpeakerDiarization else {
            return text
        }

        return DiarizedTranscriptFormatter.format(
            tokens: providerSegments ?? tokens,
            fallbackText: text,
            insertsSpacesBetweenTokens: insertsSpacesBetweenTokens
        )
    }

    func generatedTranscript(preferSpeakerDiarization: Bool) -> GeneratedTranscript {
        GeneratedTranscript(
            sourceText: text,
            tokens: tokens,
            providerSegments: providerSegments,
            insertsSpacesBetweenTokens: insertsSpacesBetweenTokens,
            preferSpeakerDiarization: preferSpeakerDiarization
        )
    }
}

struct GeneratedTranscript: Equatable {
    let text: String
    let segments: [TimedTranscriptSegment]

    init(text: String, segments: [TimedTranscriptSegment] = []) {
        self.text = text
        self.segments = segments
    }

    init(
        sourceText: String,
        tokens: [JobTranscriptionToken],
        providerSegments: [JobTranscriptionToken]?,
        insertsSpacesBetweenTokens: Bool,
        preferSpeakerDiarization: Bool
    ) {
        text = preferSpeakerDiarization
            ? DiarizedTranscriptFormatter.format(
                tokens: providerSegments ?? tokens,
                fallbackText: sourceText,
                insertsSpacesBetweenTokens: insertsSpacesBetweenTokens
            )
            : sourceText
        segments = DiarizedTranscriptFormatter.timedSegments(
            tokens: providerSegments ?? tokens,
            preserveTokenBoundaries: providerSegments != nil,
            insertsSpacesBetweenTokens: insertsSpacesBetweenTokens
        )
    }
}

enum JobStatus: String {
    case queued, uploading, processing, finalizing, completed, error
}

struct JobProgressUpdate: Equatable {
    let status: JobStatus
    let fractionCompleted: Double?

    init(status: JobStatus, progressPercent: Int? = nil) {
        self.status = status
        fractionCompleted = progressPercent.map {
            min(max(Double($0) / 100, 0), 1)
        }
    }
}

enum DiarizedTranscriptFormatter {
    private struct Segment {
        var speaker: String?
        var startMs: Int
        var endMs: Int?
        var text: String
    }

    private static let sameSpeakerGapThresholdMs = 2500

    static func format(
        tokens: [JobTranscriptionToken],
        fallbackText: String,
        insertsSpacesBetweenTokens: Bool = false
    ) -> String {
        let segments = buildSegments(
            tokens: tokens,
            insertsSpacesBetweenTokens: insertsSpacesBetweenTokens
        )
        guard !segments.isEmpty else {
            return fallbackText
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

    static func timedSegments(
        tokens: [JobTranscriptionToken],
        preserveTokenBoundaries: Bool = false,
        insertsSpacesBetweenTokens: Bool = false
    ) -> [TimedTranscriptSegment] {
        let segments = preserveTokenBoundaries
            ? providerSegments(tokens: tokens)
            : phraseSegments(
                tokens: tokens,
                insertsSpacesBetweenTokens: insertsSpacesBetweenTokens
            )
        return segments.compactMap { segment in
            let text = cleanedSegmentText(segment.text)
            guard !text.isEmpty else { return nil }
            return TimedTranscriptSegment(
                startMilliseconds: segment.startMs,
                endMilliseconds: segment.endMs,
                speaker: segment.speaker,
                text: text
            )
        }
    }

    private static func providerSegments(tokens: [JobTranscriptionToken]) -> [Segment] {
        tokens.compactMap { token in
            guard let startMs = token.startMs else { return nil }
            return Segment(
                speaker: normalizedSpeaker(token.speaker),
                startMs: startMs,
                endMs: token.endMs,
                text: token.text
            )
        }
    }

    private static func phraseSegments(
        tokens: [JobTranscriptionToken],
        insertsSpacesBetweenTokens: Bool
    ) -> [Segment] {
        var segments: [Segment] = []

        for token in tokens {
            guard !token.text.isEmpty else { continue }
            let visibleText = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if visibleText.isEmpty {
                guard !segments.isEmpty else { continue }
                segments[segments.count - 1].text += token.text
                if let endMs = token.endMs {
                    segments[segments.count - 1].endMs = endMs
                }
                continue
            }

            let speaker = normalizedSpeaker(token.speaker)
            if let startMs = token.startMs,
               shouldStartNewTimedSegment(
                   speaker: speaker,
                   startMs: startMs,
                   previous: segments.last
               )
            {
                segments.append(
                    Segment(
                        speaker: speaker,
                        startMs: startMs,
                        endMs: token.endMs,
                        text: token.text
                    )
                )
            } else if !segments.isEmpty {
                segments[segments.count - 1].text = insertsSpacesBetweenTokens
                    ? appendedText(segments[segments.count - 1].text, token.text)
                    : segments[segments.count - 1].text + token.text
                if let endMs = token.endMs {
                    segments[segments.count - 1].endMs = endMs
                }
            } else if let startMs = token.startMs {
                segments.append(
                    Segment(
                        speaker: speaker,
                        startMs: startMs,
                        endMs: token.endMs,
                        text: token.text
                    )
                )
            }
        }

        return segments
    }

    private static func shouldStartNewTimedSegment(
        speaker: String?,
        startMs: Int,
        previous: Segment?
    ) -> Bool {
        guard let previous else { return true }
        guard previous.speaker == speaker else { return true }
        if cleanedSegmentText(previous.text).last.map(isPhraseTerminator) == true {
            return true
        }
        guard let previousEndMs = previous.endMs else { return false }
        return startMs - previousEndMs > sameSpeakerGapThresholdMs
    }

    private static func buildSegments(
        tokens: [JobTranscriptionToken],
        insertsSpacesBetweenTokens: Bool
    ) -> [Segment] {
        guard tokens.contains(where: { $0.speaker != nil || $0.startMs != nil || $0.endMs != nil }) else {
            return []
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
                segments[segments.count - 1].text = insertsSpacesBetweenTokens
                    ? appendedText(segments[segments.count - 1].text, token.text)
                    : segments[segments.count - 1].text + token.text
                segments[segments.count - 1].endMs = max(segments[segments.count - 1].endMs ?? endMs, endMs)
            }
        }

        return segments
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

    private static func isPhraseTerminator(_ character: Character) -> Bool {
        ".!?…".contains(character)
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
            CharacterSet.whitespacesAndNewlines.contains(first)
        {
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

extension DiarizedTranscriptFormatter {
    /// Local transcripts labelled by `SpeakerLabeling`: same line format and same-speaker grouping
    /// as Cloud, with labels printed as they are ("Me", "Speaker 2 (remote)").
    static func format(labelledSegments: [TimedTranscriptSegment]) -> String {
        var lines: [Segment] = []
        for segment in labelledSegments {
            let text = cleanedSegmentText(segment.text)
            guard !text.isEmpty else { continue }
            if let last = lines.last, last.speaker == segment.speaker,
               segment.startMilliseconds - (last.endMs ?? last.startMs) <= sameSpeakerGapThresholdMs
            {
                lines[lines.count - 1].text = appendedText(last.text, text)
                lines[lines.count - 1].endMs = segment.endMilliseconds ?? last.endMs
            } else {
                lines.append(Segment(
                    speaker: segment.speaker,
                    startMs: segment.startMilliseconds,
                    endMs: segment.endMilliseconds,
                    text: text
                ))
            }
        }
        return lines
            .map { "[\(timestamp(for: $0.startMs))] \($0.speaker ?? "Unknown"): \($0.text)" }
            .joined(separator: "\n\n")
    }
}
