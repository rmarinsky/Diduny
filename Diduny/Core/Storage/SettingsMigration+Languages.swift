import Foundation

extension SettingsMigration {
    private enum LanguagesKey: String {
        case yourLanguages
        case defaultTranslationTargetLanguage
    }

    /// 05 §4.3 step 7 (plan 3.6 step 6). Writes `yourLanguages` and `defaultTranslationTargetLanguage`,
    /// each only when absent, with the values they already read. Never touches the pair keys,
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
                SettingsStorage.defaultTranslationTarget(in: defaults),
                forKey: LanguagesKey.defaultTranslationTargetLanguage.rawValue
            )
        }
    }
}
