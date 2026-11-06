import Foundation

/// Your languages, the one default target and the one pair (plan 3.4, ADR-0012 D4).
/// The pair keeps its existing keys, `translationLanguagePairs` and `defaultTranslationLanguagePairID`.
/// Unset values read what `SettingsMigration.migrateLanguages` writes (one function for both), so
/// existing users read the same before and after the migration.
extension SettingsStorage {
    private enum LanguagesKey: String {
        case yourLanguages
        case defaultTranslationTargetLanguage
        // Existing keys, read only to derive the values above.
        case translationLanguagePairs
        case translationLanguageA
        case translationLanguageB
        case defaultTranslationLanguagePairID
        case favoriteLanguages
    }

    /// Ordered codes; may hold codes outside the 60 Cloud languages. Setting an empty list is refused.
    var yourLanguages: [String] {
        get { yourLanguagesValue.codes }
        set {
            guard let languages = YourLanguages(newValue) else { return }
            defaults.set(languages.codes, forKey: LanguagesKey.yourLanguages.rawValue)
        }
    }

    /// "Translate into, by default": one of Your languages. Setting a language outside the list adds it.
    var defaultTranslationTargetLanguage: String {
        get { Self.defaultTranslationTarget(in: defaults) }
        set {
            guard let language = Self.normalizedLanguageCode(newValue) else { return }
            if !yourLanguages.contains(language) { yourLanguages = yourLanguages + [language] }
            defaults.set(language, forKey: LanguagesKey.defaultTranslationTargetLanguage.rawValue)
        }
    }

    /// Every pair of Your languages, for the Between and "Pair for both directions" menus.
    var offeredTranslationPairs: [TranslationLanguagePair] {
        yourLanguagesValue.offeredPairs(stored: translationLanguagePairs)
    }

    /// "Pair for both directions": Translate meeting, Translate in place, Modes, Languages, Shortcuts.
    /// Nil while Your languages has fewer than two languages Diduny Cloud translates.
    var translationPair: TranslationLanguagePair? {
        yourLanguagesValue.pair(defaultPair: defaultTranslationLanguagePair, stored: translationLanguagePairs)
    }

    /// Makes `pair` the one pair. A pair not stored yet is added; a stored pair with the same two
    /// languages is selected instead. Its languages join a stored Your languages list.
    func selectTranslationPair(_ pair: TranslationLanguagePair) {
        let stored = translationLanguagePairs
        let selected = stored.first { $0.hasSameLanguages(as: pair) } ?? pair
        if !stored.contains(selected) { translationLanguagePairs = stored + [selected] }
        defaultTranslationLanguagePairID = selected.id
        if defaults.object(forKey: LanguagesKey.yourLanguages.rawValue) != nil {
            yourLanguages = yourLanguages + selected.codes
        }
    }

    private var yourLanguagesValue: YourLanguages {
        Self.yourLanguages(in: defaults)
    }

    // MARK: - Derivation shared with the migration

    /// What `yourLanguages` reads: the stored list, else the derivation the migration writes.
    /// Reads raw `UserDefaults` because the migration runs inside `SettingsStorage.init` and cannot
    /// build a store.
    static func yourLanguages(in defaults: UserDefaults) -> YourLanguages {
        if let stored = defaults.stringArray(forKey: LanguagesKey.yourLanguages.rawValue).flatMap(YourLanguages.init) {
            return stored
        }
        let pairs = storedTranslationPairs(in: defaults)
        return YourLanguages.derived(
            storedPairs: pairs,
            favorites: normalizedLanguageCodes(
                defaults.stringArray(forKey: LanguagesKey.favoriteLanguages.rawValue) ?? YourLanguages.defaultCodes,
                fallback: YourLanguages.defaultCodes
            ),
            defaultPair: defaultTranslationPair(in: pairs ?? [.defaultPair], defaults: defaults)
        )
    }

    /// What `defaultTranslationTargetLanguage` reads; unset, Language B of the default pair.
    static func defaultTranslationTarget(in defaults: UserDefaults) -> String {
        let pairs = storedTranslationPairs(in: defaults) ?? [.defaultPair]
        return yourLanguages(in: defaults).target(
            stored: defaults.string(forKey: LanguagesKey.defaultTranslationTargetLanguage.rawValue),
            defaultPair: defaultTranslationPair(in: pairs, defaults: defaults)
        )
    }

    /// `translationLanguagePairs` as read today, or nil when neither the pair list nor the legacy
    /// single pair keys are stored.
    private static func storedTranslationPairs(in defaults: UserDefaults) -> [TranslationLanguagePair]? {
        let keys: [LanguagesKey] = [.translationLanguagePairs, .translationLanguageA, .translationLanguageB]
        guard keys.contains(where: { defaults.object(forKey: $0.rawValue) != nil }) else { return nil }
        if let data = defaults.data(forKey: LanguagesKey.translationLanguagePairs.rawValue),
           let decoded = try? JSONDecoder().decode([TranslationLanguagePair].self, from: data)
        {
            var seen = Set<Set<String>>()
            let sanitized = decoded.filter { $0.languageA != $0.languageB && seen.insert(Set($0.codes)).inserted }
            if !sanitized.isEmpty { return sanitized }
        }
        return [TranslationLanguagePair(
            languageA: defaults.string(forKey: LanguagesKey.translationLanguageA.rawValue) ?? "en",
            languageB: defaults.string(forKey: LanguagesKey.translationLanguageB.rawValue) ?? "uk"
        )]
    }

    /// `defaultTranslationLanguagePair` as read today.
    private static func defaultTranslationPair(
        in pairs: [TranslationLanguagePair],
        defaults: UserDefaults
    ) -> TranslationLanguagePair {
        let storedID = defaults.string(forKey: LanguagesKey.defaultTranslationLanguagePairID.rawValue)
        return pairs.first { $0.id == storedID } ?? pairs.first ?? .defaultPair
    }
}
