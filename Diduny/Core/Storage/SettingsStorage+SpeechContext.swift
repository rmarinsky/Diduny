import Foundation

/// Settings > Languages > Vocabulary and context: what Diduny Cloud receives as `user_context`.
extension SettingsStorage {
    private enum SpeechContextKey: String {
        case speechVocabularyTerms
        case speechDomain
        case speechTranslationTerms
        case speechUsesCalendarContext
    }

    /// Words and names the engine should expect, in the person's order.
    var speechVocabularyTerms: [String] {
        get { defaults.stringArray(forKey: SpeechContextKey.speechVocabularyTerms.rawValue) ?? [] }
        set { defaults.set(newValue, forKey: SpeechContextKey.speechVocabularyTerms.rawValue) }
    }

    /// What the person usually talks about. Empty leaves the backend default.
    var speechDomain: String {
        get { defaults.string(forKey: SpeechContextKey.speechDomain.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: SpeechContextKey.speechDomain.rawValue) }
    }

    /// Source → target pairs, sent only with translation requests.
    var speechTranslationTerms: [SpeechTranslationTerm] {
        get {
            let stored = defaults.array(forKey: SpeechContextKey.speechTranslationTerms.rawValue) as? [[String: String]] ?? []
            return stored.compactMap { item in
                guard let source = item["source"], let target = item["target"] else { return nil }
                return SpeechTranslationTerm(source: source, target: target)
            }
        }
        set {
            defaults.set(newValue.map { ["source": $0.source, "target": $0.target] },
                         forKey: SpeechContextKey.speechTranslationTerms.rawValue)
        }
    }

    /// Meeting title and attendee names go with meeting recordings. On by default.
    var speechUsesCalendarContext: Bool {
        get { defaults.object(forKey: SpeechContextKey.speechUsesCalendarContext.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: SpeechContextKey.speechUsesCalendarContext.rawValue) }
    }
}
