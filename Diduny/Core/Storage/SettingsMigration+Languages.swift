import Foundation

extension SettingsMigration {
    private enum LanguagesKey: String {
        case yourLanguages
        case defaultTranslationTargetLanguage
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
