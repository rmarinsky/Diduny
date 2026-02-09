import Foundation
import Observation
import os

@Observable
@MainActor
final class LiveTranscriptStore {
    var segments: [TranscriptSegment] = []
    var provisionalText: String = ""
    var provisionalSpeaker: String?
    var isActive: Bool = false
    var connectionStatus: RealtimeConnectionStatus = .disconnected

    var wordCount: Int {
        let finalWords = segments.reduce(0) { count, segment in
            count + segment.text.split(separator: " ").count
        }
        let provisionalWords = provisionalText.split(separator: " ").count
        return finalWords + provisionalWords
    }

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

        // Update provisional text
        if !nonFinalTokens.isEmpty {
            provisionalText = nonFinalTokens.map(\.text).joined()
            provisionalSpeaker = nonFinalTokens.first?.speaker
        } else if !finalTokens.isEmpty {
            provisionalText = ""
            provisionalSpeaker = nil
        }
    }

    private func appendFinalToken(_ token: RealtimeToken) {
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

    // MARK: - Reset

    func reset() {
        segments = []
        provisionalText = ""
        provisionalSpeaker = nil
        isActive = false
        connectionStatus = .disconnected
    }
}
