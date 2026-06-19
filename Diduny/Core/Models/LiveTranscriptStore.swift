import Foundation
import Observation
import os

@Observable
@MainActor
final class LiveTranscriptStore {
    let createdAt = Date()
    var segments: [TranscriptSegment] = []
    var provisionalText: String = ""
    var provisionalSpeaker: String?
    var isActive: Bool = false
    var connectionStatus: RealtimeConnectionStatus = .disconnected
    private var forceNewSegmentForNextFinalToken = false

    private(set) var wordCount: Int = 0
    private var _provisionalWordCount: Int = 0

    var finalTranscriptText: String {
        var result = ""
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let speakerLabel = segment.speaker.map { "Speaker \($0)" } ?? "Unknown"
            result += "[\(segment.timestamp)] \(speakerLabel): \(text)\n\n"
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Process Tokens

    func processTokens(_ tokens: [RealtimeToken]) {
        let finalTokens = tokens.filter(\.isFinal)
        let nonFinalTokens = tokens.filter { !$0.isFinal }

        // Append final tokens to segments
        for token in finalTokens {
            appendFinalToken(token)
        }

        // Update provisional text and word count
        if !nonFinalTokens.isEmpty {
            let newText = nonFinalTokens.map(\.text).joined()
            let newCount = newText.split(separator: " ").filter { !$0.isEmpty }.count
            wordCount += newCount - _provisionalWordCount
            _provisionalWordCount = newCount
            provisionalText = newText
            provisionalSpeaker = nonFinalTokens.first?.speaker
        } else if !finalTokens.isEmpty {
            wordCount -= _provisionalWordCount
            _provisionalWordCount = 0
            provisionalText = ""
            provisionalSpeaker = nil
        }
    }

    private func appendFinalToken(_ token: RealtimeToken) {
        wordCount += token.text.split(separator: " ").filter { !$0.isEmpty }.count
        if forceNewSegmentForNextFinalToken {
            forceNewSegmentForNextFinalToken = false
            let segment = TranscriptSegment(
                speaker: token.speaker,
                tokens: [token],
                startMs: token.startMs
            )
            segments.append(segment)
            return
        }

        // If current segment has same speaker, append
        if let lastIndex = segments.indices.last,
           segments[lastIndex].speaker == token.speaker
        {
            segments[lastIndex].tokens.append(token)
        } else {
            // New speaker or first segment
            let segment = TranscriptSegment(
                speaker: token.speaker,
                tokens: [token],
                startMs: token.startMs
            )
            segments.append(segment)
        }
    }

    func markSegmentBoundary() {
        guard !segments.isEmpty else { return }
        forceNewSegmentForNextFinalToken = true
    }

    // MARK: - Reset

    func reset() {
        segments = []
        provisionalText = ""
        provisionalSpeaker = nil
        wordCount = 0
        _provisionalWordCount = 0
        isActive = false
        connectionStatus = .disconnected
        forceNewSegmentForNextFinalToken = false
    }
}
