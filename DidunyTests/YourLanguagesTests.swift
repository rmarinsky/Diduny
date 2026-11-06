@testable import Diduny
import Foundation
import Testing

/// WP-14: Your languages, the one default target and the one pair (plan 3.4, 05 §2.3, §4.3 step 7).
/// Every test uses its own `UserDefaults` suite, never `SettingsStorage.shared` (test-plan 7.6).
final class YourLanguagesTests {
    private let suiteName = "YourLanguagesTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func storage() -> SettingsStorage {
        SettingsStorage(defaults: defaults)
    }

    private func storePairs(_ pairs: [TranslationLanguagePair], defaultID: String? = nil) throws {
        defaults.set(try JSONEncoder().encode(pairs), forKey: "translationLanguagePairs")
        if let defaultID { defaults.set(defaultID, forKey: "defaultTranslationLanguagePairID") }
    }

    private func pair(_ a: String, _ b: String) -> TranslationLanguagePair {
        TranslationLanguagePair(languageA: a, languageB: b)
    }

    // MARK: - Pure model

    @Test("T5-LA-01 pairs come from Your languages, every two in list order")
    func pairsDerivedInListOrder() throws {
        let four = try #require(YourLanguages(["en", "uk", "pl", "de"]))
        #expect(four.pairs.map(\.id) == ["en-uk", "en-pl", "en-de", "uk-pl", "uk-de", "pl-de"])
        #expect(try #require(YourLanguages(["en", "uk"])).pairs.map(\.id) == ["en-uk"])
        #expect(try #require(YourLanguages(["en"])).pairs.isEmpty)
    }

    @Test("Codes are normalized and deduplicated; an empty list is refused")
    func normalizesAndDedupes() throws {
        let languages = try #require(YourLanguages([" EN ", "uk-UA", "ua", "en", "invalid", "pl_PL"]))
        #expect(languages.codes == ["en", "uk", "pl"])
        #expect(YourLanguages([]) == nil)
        #expect(YourLanguages(["invalid", " "]) == nil)
    }

    @Test("Maltese, outside the 60 Cloud languages, can be stored but forms no Cloud pair")
    func malteseCanBeStored() throws {
        let languages = try #require(YourLanguages(["en", "MT", "uk"]))
        #expect(languages.codes == ["en", "mt", "uk"])
        #expect(languages.translatableCodes == ["en", "uk"])
        #expect(languages.pairs.map(\.id) == ["en-uk"])

        let store = storage()
        store.yourLanguages = ["en", "mt"]
        #expect(store.yourLanguages == ["en", "mt"])
        #expect(defaults.stringArray(forKey: "yourLanguages") == ["en", "mt"])
    }

    @Test("The Cloud normalizer still rejects codes outside the 60")
    func cloudNormalizerUnchanged() {
        #expect(SupportedLanguage.normalizedCode("mt") == nil)
        #expect(SupportedLanguage.normalizedCode("ua") == "uk")
        #expect(TranslationLanguagePair(languageA: "en", languageB: "mt").languageB == "uk")
    }

    @Test("T5-LA-02 the last language cannot be removed; a new pick goes to the end")
    func keepsAtLeastOne() throws {
        let one = try #require(YourLanguages(["en"]))
        #expect(one.removing("en").codes == ["en"])
        #expect(one.adding("pl").codes == ["en", "pl"])
        #expect(one.adding("pl").adding("EN").codes == ["en", "pl"])
        #expect(one.adding("pl").removing("en").codes == ["pl"])

        let store = storage()
        store.yourLanguages = ["en"]
        store.yourLanguages = []
        #expect(store.yourLanguages == ["en"])
    }

    @Test("T5-LA-03 the default target falls back to the first of Your languages")
    func targetFallsBack() {
        let store = storage()
        store.yourLanguages = ["en", "pl"]
        store.defaultTranslationTargetLanguage = "pl"
        #expect(store.defaultTranslationTargetLanguage == "pl")

        store.yourLanguages = ["en"]
        #expect(store.defaultTranslationTargetLanguage == "en")
    }

    @Test("T5-LA-04 the pair falls back to the first pair of Your languages")
    func pairFallsBack() throws {
        let store = storage()
        store.yourLanguages = ["en", "uk", "pl"]
        store.selectTranslationPair(pair("en", "pl"))
        #expect(store.translationPair?.id == "en-pl")

        store.yourLanguages = ["en", "uk"]
        #expect(store.translationPair?.id == "en-uk")

        store.yourLanguages = ["en"]
        #expect(store.translationPair == nil)
    }

    @Test("T5-LA-05 (partial, WP-14 part) Languages you speak keep their order; unticking a detected language is stored")
    func languagesYouSpeakPartial() {
        let store = storage()
        store.manualSpeechLanguageHints = []
        #expect(store.manualSpeechLanguageHints.isEmpty)
        // WP-53: with nothing chosen or detected, no hint is sent.
        #expect(store.effectiveSpeechLanguageHints(detectedCodes: []).isEmpty)

        store.manualSpeechLanguageHints = ["pl", "en"]
        #expect(store.manualSpeechLanguageHints == ["pl", "en"])

        store.setDetectedSpeechLanguage("uk", enabled: false)
        #expect(store.disabledDetectedSpeechLanguageHints.contains("uk"))
        #expect(store.effectiveSpeechLanguageHints(detectedCodes: ["uk", "en"]) == ["en", "pl"])
    }

    @Test("Pair labels: short codes and full names")
    func pairLabels() {
        let english = Locale(identifier: "en")
        #expect(pair("en", "uk").shortLabel == "EN ↔ UK")
        #expect(pair("en", "uk").fullName(locale: english) == "English ↔ Ukrainian")
        #expect(pair("pl", "de").fullName(locale: english) == "Polish ↔ German")
        #expect(pair("en", "uk").displayLabel == "EN ⇄ UK")
    }

    // MARK: - The one pair, shared by every place that edits it

    @Test("T1-TM-01 Between menu rows: pairs of Your languages, the default selected, field EN ↔ UK")
    func betweenMenuRows() throws {
        let store = storage()
        store.yourLanguages = ["en", "uk", "pl", "de"]
        let english = Locale(identifier: "en")
        #expect(store.offeredTranslationPairs.map { $0.fullName(locale: english) } == [
            "English ↔ Ukrainian", "English ↔ Polish", "English ↔ German",
            "Ukrainian ↔ Polish", "Ukrainian ↔ German", "Polish ↔ German"
        ])
        let selected = try #require(store.translationPair)
        #expect(selected.id == "en-uk")
        #expect(selected.shortLabel == "EN ↔ UK")
    }

    @Test("T5-MD-07 picking a pair not stored adds it; every reader sees the same pair")
    func onePairValue() throws {
        let store = storage()
        store.yourLanguages = ["en", "uk", "pl"]

        store.selectTranslationPair(pair("en", "pl"))
        #expect(store.defaultTranslationLanguagePairID == "en-pl")
        #expect(store.translationLanguagePairs.map(\.id) == ["en-uk", "en-pl"])
        #expect(store.translationPair?.id == "en-pl")
        #expect(SettingsStorage(defaults: defaults).translationPair?.id == "en-pl")

        // The same pair in the other direction selects the stored one, without a duplicate.
        store.selectTranslationPair(pair("uk", "en"))
        #expect(store.defaultTranslationLanguagePairID == "en-uk")
        #expect(store.translationLanguagePairs.map(\.id) == ["en-uk", "en-pl"])
    }

    @Test("A picked pair adds missing languages to a stored Your languages")
    func pickedPairAddsLanguages() {
        let store = storage()
        store.yourLanguages = ["en", "uk"]
        store.selectTranslationPair(pair("en", "de"))
        #expect(store.yourLanguages == ["en", "uk", "de"])
        #expect(store.translationPair?.id == "en-de")
    }

    @Test("Picking a pair keeps Your languages derived from favorites")
    func pickedPairKeepsFavorites() {
        defaults.set(["de", "fr"], forKey: "favoriteLanguages")
        let store = storage()
        #expect(store.yourLanguages == ["de", "fr", "en", "uk"])
        store.selectTranslationPair(pair("en", "pl"))
        #expect(store.yourLanguages == ["de", "fr", "en", "uk", "pl"])
        #expect(store.translationPair?.id == "en-pl")
    }

    @Test("A stored pair keeps its direction and id in the offered list")
    func storedPairDirectionKept() throws {
        try storePairs([pair("uk", "en"), pair("de", "en")], defaultID: "de-en")
        let store = storage()
        #expect(store.offeredTranslationPairs.map(\.id) == ["uk-en", "uk-de", "de-en"])
        #expect(store.translationPair?.id == "de-en")
        #expect(store.defaultTranslationTargetLanguage == "uk")
    }

    // MARK: - Read-time defaults for users who never saw the new keys

    @Test("Fresh install: Your languages English, Ukrainian; target English; pair EN ↔ UK")
    func freshInstallDefaults() {
        let store = storage()
        #expect(store.yourLanguages == ["en", "uk"])
        #expect(store.defaultTranslationTargetLanguage == "en")
        #expect(store.translationPair?.id == "en-uk")
        #expect(defaults.object(forKey: "yourLanguages") == nil)
        #expect(defaults.object(forKey: "defaultTranslationTargetLanguage") == nil)
    }

    @Test("Your languages and the pair read the same before and after the migration; the target becomes Language B")
    func readTimeEqualsMigration() throws {
        try storePairs([pair("en", "uk"), pair("uk", "pl"), pair("de", "en")], defaultID: "uk-pl")
        let before = storage()
        let languages = before.yourLanguages
        let target = before.defaultTranslationTargetLanguage
        let pairID = before.translationPair?.id

        SettingsMigration.migrateLanguages(defaults: defaults)

        let after = storage()
        #expect(after.yourLanguages == languages)
        #expect(target == "en")
        #expect(after.defaultTranslationTargetLanguage == "pl")
        #expect(after.translationPair?.id == pairID)
        #expect(pairID == before.defaultTranslationLanguagePair.id)
    }

    @Test("The default target setter normalizes and adds the language to Your languages")
    func targetSetterAddsToYourLanguages() {
        let store = storage()
        store.defaultTranslationTargetLanguage = " FR "
        #expect(store.defaultTranslationTargetLanguage == "fr")
        #expect(store.yourLanguages == ["en", "uk", "fr"])

        store.defaultTranslationTargetLanguage = "invalid"
        #expect(store.defaultTranslationTargetLanguage == "fr")
    }

    // MARK: - Migration step (05 §4.3 step 7, plan 3.6 step 6)

    @Test("T5-MIG-18 Your languages from pairs: pair order, A then B, deduplicated")
    func migrationFromPairs() throws {
        try storePairs([pair("en", "uk"), pair("uk", "pl"), pair("de", "en")], defaultID: "en-uk")
        SettingsMigration.migrateLanguages(defaults: defaults)
        #expect(defaults.stringArray(forKey: "yourLanguages") == ["en", "uk", "pl", "de"])
    }

    @Test("T5-MIG-19 with no pairs, Your languages fall back to favoriteLanguages")
    func migrationFallsBackToFavorites() {
        defaults.set(["uk", "en"], forKey: "favoriteLanguages")
        SettingsMigration.migrateLanguages(defaults: defaults)
        #expect(defaults.stringArray(forKey: "yourLanguages") == ["uk", "en"])
    }

    @Test("With no pairs, the pair the app uses today is still offered")
    func migrationKeepsImplicitPair() {
        defaults.set(["de", "fr"], forKey: "favoriteLanguages")
        SettingsMigration.migrateLanguages(defaults: defaults)
        let store = storage()
        #expect(store.yourLanguages == ["de", "fr", "en", "uk"])
        #expect(store.translationPair?.id == store.defaultTranslationLanguagePair.id)
        #expect(store.defaultTranslationTargetLanguage == "uk")
    }

    @Test("T5-MIG-20 default target is Language B of the default pair; nothing else is written")
    func migrationDefaultTarget() throws {
        try storePairs([pair("en", "uk"), pair("en", "pl")], defaultID: "en-uk")
        SettingsMigration.migrateLanguages(defaults: defaults)
        #expect(defaults.string(forKey: "defaultTranslationTargetLanguage") == "uk")
        #expect(defaults.object(forKey: "dictationTranslationTargetLanguage") == nil)
        #expect(defaults.string(forKey: "defaultTranslationLanguagePairID") == "en-uk")
    }

    @Test("T5-MIG-21 every stored pair is still offered", arguments: [
        ["en-uk", "uk-pl"],
        ["en-uk", "uk-pl", "de-en"],
        ["pl-en", "fr-de"]
    ])
    func migrationOffersEveryStoredPair(ids: [String]) throws {
        let stored = ids.map { id in
            let codes = id.split(separator: "-").map(String.init)
            return pair(codes[0], codes[1])
        }
        try storePairs(stored)
        SettingsMigration.migrateLanguages(defaults: defaults)
        let offered = storage().offeredTranslationPairs.map(\.id)
        for id in ids {
            #expect(offered.contains(id), "\(id) not in \(offered)")
        }
    }

    @Test("T5-MIG-22 legacy single pair keys")
    func migrationFromLegacyPairKeys() {
        defaults.set("en", forKey: "translationLanguageA")
        defaults.set("pl", forKey: "translationLanguageB")
        #expect(storage().translationLanguagePairs == [pair("en", "pl")])

        SettingsMigration.migrateLanguages(defaults: defaults)
        #expect(defaults.stringArray(forKey: "yourLanguages") == ["en", "pl"])
        #expect(defaults.string(forKey: "defaultTranslationTargetLanguage") == "pl")
    }

    @Test("The step is idempotent, keeps values already written and deletes no legacy key")
    func migrationIdempotentAndNonDestructive() throws {
        try storePairs([pair("en", "uk")], defaultID: "en-uk")
        defaults.set(["en", "uk"], forKey: "favoriteLanguages")
        defaults.set("en-uk", forKey: "lastUsedTranslationLanguagePairID")
        defaults.set(["de", "en"], forKey: "yourLanguages")
        defaults.set("de", forKey: "defaultTranslationTargetLanguage")

        SettingsMigration.migrateLanguages(defaults: defaults)
        SettingsMigration.migrateLanguages(defaults: defaults)

        #expect(defaults.stringArray(forKey: "yourLanguages") == ["de", "en"])
        #expect(defaults.string(forKey: "defaultTranslationTargetLanguage") == "de")
        #expect(defaults.data(forKey: "translationLanguagePairs") != nil)
        #expect(defaults.stringArray(forKey: "favoriteLanguages") == ["en", "uk"])
        #expect(defaults.string(forKey: "lastUsedTranslationLanguagePairID") == "en-uk")
    }

    // MARK: - Voice command position

    @Test("The command position stores the new value anywhere")
    func commandPositionAnywhere() {
        let store = storage()
        #expect(store.voiceTranslationCommandPosition == .startAndEnd)
        store.voiceTranslationCommandPosition = .anywhere
        #expect(defaults.string(forKey: "voiceTranslationCommandPosition") == "anywhere")
        #expect(SettingsStorage(defaults: defaults).voiceTranslationCommandPosition == .anywhere)
    }
}
