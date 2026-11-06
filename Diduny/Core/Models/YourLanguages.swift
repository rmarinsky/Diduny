import Foundation

/// "Your languages": the ordered languages every language menu shows first (plan 3.4, 05 §2.3).
/// Pure value. Codes outside the 60 Diduny Cloud languages (Maltese) can be stored; only the 60
/// form pairs and targets, so the Cloud request path is unchanged.
struct YourLanguages: Equatable {
    static let defaultCodes = ["en", "uk"]

    /// Normalized, deduplicated, never empty.
    let codes: [String]

    /// Nil when no valid code is left: the list keeps at least one language.
    init?(_ rawCodes: [String]) {
        var seen = Set<String>()
        let codes = rawCodes.compactMap(SupportedLanguage.normalizedISOCode).filter { seen.insert($0).inserted }
        guard !codes.isEmpty else { return nil }
        self.codes = codes
    }

    /// 05 §4.3 step 7: languages of the stored pairs in pair order (A then B). With no stored pair,
    /// `favoriteLanguages`, then the languages of the pair the app uses today, so that pair stays offered.
    static func derived(
        storedPairs: [TranslationLanguagePair]?,
        favorites: [String],
        defaultPair: TranslationLanguagePair
    ) -> YourLanguages {
        let codes = storedPairs.map { $0.flatMap(\.codes) } ?? favorites + defaultPair.codes
        return YourLanguages(codes) ?? YourLanguages(defaultCodes)!
    }

    /// A newly picked language goes to the end.
    func adding(_ code: String) -> YourLanguages {
        YourLanguages(codes + [code]) ?? self
    }

    /// Removing the last language is refused.
    func removing(_ code: String) -> YourLanguages {
        let removed = SupportedLanguage.normalizedISOCode(code)
        return YourLanguages(codes.filter { $0 != removed }) ?? self
    }

    /// The codes Diduny Cloud translates (the 60), in list order.
    var translatableCodes: [String] {
        codes.filter { SupportedLanguage.normalizedCode($0) == $0 }
    }

    /// Every two translatable languages, in list order: six for four languages.
    var pairs: [TranslationLanguagePair] {
        let codes = translatableCodes
        return codes.indices.flatMap { first in
            codes[(first + 1)...].map { TranslationLanguagePair(languageA: codes[first], languageB: $0) }
        }
    }

    /// The pairs to offer: a stored pair with the same two languages replaces the derived one,
    /// so it keeps its direction and id.
    func offeredPairs(stored: [TranslationLanguagePair]) -> [TranslationLanguagePair] {
        pairs.map { derived in stored.first { $0.hasSameLanguages(as: derived) } ?? derived }
    }

    /// The one pair: the default pair if it is offered, else the first offered pair; nil with fewer
    /// than two translatable languages.
    func pair(defaultPair: TranslationLanguagePair, stored: [TranslationLanguagePair]) -> TranslationLanguagePair? {
        let offered = offeredPairs(stored: stored)
        return offered.first { $0.hasSameLanguages(as: defaultPair) } ?? offered.first
    }

    /// The one default target: the stored one while it is in the list; unset, Language B of the
    /// default pair; else the first translatable language.
    func target(stored: String?, defaultPair: TranslationLanguagePair) -> String {
        let candidates = translatableCodes
        if let stored = SupportedLanguage.normalizedCode(stored) {
            if candidates.contains(stored) { return stored }
        } else if candidates.contains(defaultPair.languageB) {
            return defaultPair.languageB
        }
        return candidates.first ?? defaultPair.languageB
    }
}

extension TranslationLanguagePair {
    func hasSameLanguages(as other: TranslationLanguagePair) -> Bool {
        Set(codes) == Set(other.codes)
    }

    /// Field value, "EN ↔ UK".
    var shortLabel: String {
        let a = languageA.uppercased(), b = languageB.uppercased()
        return String(localized: "\(a) ↔ \(b)")
    }

    /// Menu row, "English ↔ Ukrainian", in the app's language unless a locale is given.
    func fullName(locale: Locale? = nil) -> String {
        let locale = locale ?? Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let a = Self.name(languageA, locale), b = Self.name(languageB, locale)
        return String(localized: "\(a) ↔ \(b)")
    }

    private static func name(_ code: String, _ locale: Locale) -> String {
        locale.localizedString(forLanguageCode: code) ?? SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }
}
