import Foundation

struct SpeechTranslationTerm: Equatable {
    var source: String
    var target: String
}

/// What the person told Diduny Cloud to expect (Settings > Languages > Vocabulary and context), sent in the
/// config as `user_context`. The backend merges it into the Soniox `context`; the limits mirror its validation.
struct SpeechUserContext: Equatable {
    static let domainLimit = 200
    static let textLimit = 3000
    static let itemLimit = 80
    static let termsLimit = 300
    static let translationTermsLimit = 200

    var domain = ""
    var text = ""
    var terms: [String] = []
    var translationTerms: [SpeechTranslationTerm] = []

    /// Trimmed, deduplicated and cut to the limits; nil when nothing is left. The glossary goes only with translation.
    func payload(translation: Bool) -> [String: Any]? {
        var result: [String: Any] = [:]
        let domain = Self.clamp(domain, Self.domainLimit)
        if !domain.isEmpty { result["domain"] = domain }
        let text = Self.clamp(text, Self.textLimit)
        if !text.isEmpty { result["text"] = text }

        var seen = Set<String>()
        let terms = terms.map { Self.clamp($0, Self.itemLimit) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(Self.termsLimit)
        if !terms.isEmpty { result["terms"] = Array(terms) }

        if translation {
            var seenSources = Set<String>()
            let pairs = translationTerms
                .map { (Self.clamp($0.source, Self.itemLimit), Self.clamp($0.target, Self.itemLimit)) }
                .filter { !$0.0.isEmpty && !$0.1.isEmpty && seenSources.insert($0.0.lowercased()).inserted }
                .prefix(Self.translationTermsLimit)
                .map { ["source": $0.0, "target": $0.1] }
            if !pairs.isEmpty { result["translation_terms"] = pairs }
        }
        return result.isEmpty ? nil : result
    }

    /// Adds `user_context` to a Diduny Cloud config; a config with `translation` also gets the glossary.
    func apply(to config: inout [String: Any]) {
        if let payload = payload(translation: config["translation"] != nil) {
            config["user_context"] = payload
        }
    }

    /// From Settings: the person's words, then Diduny's built-in names, then the meeting's attendees.
    static func current(calendarMeeting: CalendarMeeting? = nil, settings: SettingsStorage = .shared) -> SpeechUserContext {
        let meeting = settings.speechUsesCalendarContext ? calendarMeeting : nil
        // Attendees with only an email give no spoken name.
        let attendees = meeting?.attendees?.compactMap { $0.name?.nilIfBlank }.filter { !$0.contains("@") } ?? []
        return SpeechUserContext(
            domain: settings.speechDomain,
            text: meeting?.title.nilIfBlank.map { "Meeting: \($0)" } ?? "",
            terms: settings.speechVocabularyTerms
                + ProtectedLexiconService.shared.vocabularyHints(language: nil, limit: termsLimit)
                + attendees,
            translationTerms: settings.speechTranslationTerms
        )
    }

    private static func clamp(_ value: String, _ limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
