import Foundation

/// Back-fills timestamps on Soniox translation tokens from their preceding original tokens.
///
/// Soniox omits `start_ms` / `end_ms` on tokens with `translation_status == "translation"`.
/// Originals and translations arrive interleaved in one ordered stream, with translations
/// following the spoken tokens they translate. This tracker records utterance starts from
/// original tokens and stamps them onto subsequent translation tokens so
/// `LiveTranscriptStore` / `LiveTranscriptView` can render advancing `[MM:SS]` labels.
final class TranslationTimestampBackfill: @unchecked Sendable {
    private let lock = NSLock()
    private var utteranceStartBySpeaker: [String: Int] = [:]
    private var currentSpeakerKey: String?
    private var lastGlobalStartMs: Int?

    /// Annotates a batch of tokens in arrival order. Non-translation tokens pass through
    /// and update utterance tracking; translation tokens get rewritten timestamps.
    func annotate(_ tokens: [RealtimeToken]) -> [RealtimeToken] {
        guard !tokens.isEmpty else { return tokens }

        lock.lock()
        defer { lock.unlock() }

        return tokens.map { token in
            if isTranslationToken(token) {
                return annotateTranslation(token)
            }
            recordOriginal(token)
            return token
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        utteranceStartBySpeaker.removeAll()
        currentSpeakerKey = nil
        lastGlobalStartMs = nil
    }

    private func isTranslationToken(_ token: RealtimeToken) -> Bool {
        guard let status = token.translationStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !status.isEmpty
        else {
            return false
        }
        return status == "translation"
            || status == "translated"
            || status == "translated_text"
            || status == "translation_text"
            || status == "target"
            || status == "output"
    }

    private func speakerKey(for token: RealtimeToken) -> String {
        token.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func recordOriginal(_ token: RealtimeToken) {
        let key = speakerKey(for: token)
        if key != currentSpeakerKey {
            currentSpeakerKey = key
            utteranceStartBySpeaker[key] = token.startMs
        } else if utteranceStartBySpeaker[key] == nil {
            utteranceStartBySpeaker[key] = token.startMs
        }
        lastGlobalStartMs = utteranceStartBySpeaker[key] ?? token.startMs
    }

    private func annotateTranslation(_ token: RealtimeToken) -> RealtimeToken {
        let key = speakerKey(for: token)
        let startMs = utteranceStartBySpeaker[key] ?? lastGlobalStartMs ?? token.startMs
        return RealtimeToken(
            text: token.text,
            isFinal: token.isFinal,
            speaker: token.speaker,
            startMs: startMs,
            endMs: startMs,
            language: token.language,
            sourceLanguage: token.sourceLanguage,
            translationStatus: token.translationStatus
        )
    }
}
