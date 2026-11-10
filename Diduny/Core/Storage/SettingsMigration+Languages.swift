import Foundation

extension SettingsMigration {
    private enum LanguagesKey: String {
        case yourLanguages
        case defaultTranslationTargetLanguage
        case manualSpeechLanguageHints
        case disabledDetectedSpeechLanguageHints
    }

    /// Seeds an unset "Your languages" once from what the hints used to be: the keyboard-layout languages
    /// the person had not switched off, then their own picks. A stored list is never touched; with
    /// nothing detected the key stays unset and the existing derivation applies.
    static func seedYourLanguages(defaults: UserDefaults, detected: [String]) {
        guard defaults.object(forKey: LanguagesKey.yourLanguages.rawValue) == nil else { return }
        let disabled = Set(defaults.stringArray(forKey: LanguagesKey.disabledDetectedSpeechLanguageHints.rawValue) ?? [])
        let enabled = detected.compactMap { SupportedLanguage.normalizedCode($0) }.filter { !disabled.contains($0) }
        guard !enabled.isEmpty else { return }
        let manual = defaults.stringArray(forKey: LanguagesKey.manualSpeechLanguageHints.rawValue) ?? []
        guard let seed = YourLanguages(enabled + manual) else { return }
        defaults.set(seed.codes, forKey: LanguagesKey.yourLanguages.rawValue)
    }

    /// 05 §4.3 step 7 (plan 3.6 step 6). Writes `yourLanguages` (the value it already reads) and
    /// `defaultTranslationTargetLanguage` = Language B of the default pair, each only when absent.
    /// Never touches the pair keys,
    /// `favoriteLanguages` or `lastUsedTranslationLanguagePairID`. Idempotent.
    static func migrateLanguages(defaults: UserDefaults) {
        if defaults.object(forKey: LanguagesKey.yourLanguages.rawValue) == nil {
            defaults.set(
                SettingsStorage.yourLanguages(in: defaults).codes,
                forKey: LanguagesKey.yourLanguages.rawValue
            )
        }
        if defaults.object(forKey: LanguagesKey.defaultTranslationTargetLanguage.rawValue) == nil {
            defaults.set(
                SettingsStorage.defaultTranslationPair(in: defaults).languageB,
                forKey: LanguagesKey.defaultTranslationTargetLanguage.rawValue
            )
        }
    }
}
