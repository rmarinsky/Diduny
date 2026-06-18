@testable import Diduny
import XCTest

final class SettingsStorageProviderTests: XCTestCase {
    private let transcriptionProviderKey = "transcriptionProvider"
    private let dictationRetentionKey = "dictationTranslationHistoryRetentionPolicy"
    private let meetingRetentionKey = "meetingHistoryRetentionPolicy"
    private let favoriteLanguagesKey = "favoriteLanguages"
    private let manualSpeechLanguageHintsKey = "manualSpeechLanguageHints"
    private let disabledDetectedSpeechLanguageHintsKey = "disabledDetectedSpeechLanguageHints"
    private let translationLanguageAKey = "translationLanguageA"
    private let translationLanguageBKey = "translationLanguageB"
    private let translationLanguagePairsKey = "translationLanguagePairs"
    private let defaultTranslationLanguagePairIDKey = "defaultTranslationLanguagePairID"
    private let lastUsedTranslationLanguagePairIDKey = "lastUsedTranslationLanguagePairID"
    private let translationTargetLanguagesKey = "translationTargetLanguages"
    private let voiceTranslationTargetLanguageKey = "voiceTranslationTargetLanguage"
    private let textTranslationSourceLanguageKey = "textTranslationSourceLanguage"
    private let textTranslationTargetLanguageKey = "textTranslationTargetLanguage"
    private var storedProvider: Any?
    private var storedDictationRetention: Any?
    private var storedMeetingRetention: Any?
    private var storedFavoriteLanguages: Any?
    private var storedManualSpeechLanguageHints: Any?
    private var storedDisabledDetectedSpeechLanguageHints: Any?
    private var storedTranslationLanguageA: Any?
    private var storedTranslationLanguageB: Any?
    private var storedTranslationLanguagePairs: Any?
    private var storedDefaultTranslationLanguagePairID: Any?
    private var storedLastUsedTranslationLanguagePairID: Any?
    private var storedTranslationTargetLanguages: Any?
    private var storedVoiceTranslationTargetLanguage: Any?
    private var storedTextTranslationSourceLanguage: Any?
    private var storedTextTranslationTargetLanguage: Any?

    override func setUp() {
        super.setUp()
        storedProvider = UserDefaults.standard.object(forKey: transcriptionProviderKey)
        storedDictationRetention = UserDefaults.standard.object(forKey: dictationRetentionKey)
        storedMeetingRetention = UserDefaults.standard.object(forKey: meetingRetentionKey)
        storedFavoriteLanguages = UserDefaults.standard.object(forKey: favoriteLanguagesKey)
        storedManualSpeechLanguageHints = UserDefaults.standard.object(forKey: manualSpeechLanguageHintsKey)
        storedDisabledDetectedSpeechLanguageHints = UserDefaults.standard.object(
            forKey: disabledDetectedSpeechLanguageHintsKey
        )
        storedTranslationLanguageA = UserDefaults.standard.object(forKey: translationLanguageAKey)
        storedTranslationLanguageB = UserDefaults.standard.object(forKey: translationLanguageBKey)
        storedTranslationLanguagePairs = UserDefaults.standard.object(forKey: translationLanguagePairsKey)
        storedDefaultTranslationLanguagePairID = UserDefaults.standard.object(forKey: defaultTranslationLanguagePairIDKey)
        storedLastUsedTranslationLanguagePairID = UserDefaults.standard.object(forKey: lastUsedTranslationLanguagePairIDKey)
        storedTranslationTargetLanguages = UserDefaults.standard.object(forKey: translationTargetLanguagesKey)
        storedVoiceTranslationTargetLanguage = UserDefaults.standard.object(forKey: voiceTranslationTargetLanguageKey)
        storedTextTranslationSourceLanguage = UserDefaults.standard.object(forKey: textTranslationSourceLanguageKey)
        storedTextTranslationTargetLanguage = UserDefaults.standard.object(forKey: textTranslationTargetLanguageKey)
    }

    override func tearDown() {
        restore(storedProvider, key: transcriptionProviderKey)
        restore(storedDictationRetention, key: dictationRetentionKey)
        restore(storedMeetingRetention, key: meetingRetentionKey)
        restore(storedFavoriteLanguages, key: favoriteLanguagesKey)
        restore(storedManualSpeechLanguageHints, key: manualSpeechLanguageHintsKey)
        restore(storedDisabledDetectedSpeechLanguageHints, key: disabledDetectedSpeechLanguageHintsKey)
        restore(storedTranslationLanguageA, key: translationLanguageAKey)
        restore(storedTranslationLanguageB, key: translationLanguageBKey)
        restore(storedTranslationLanguagePairs, key: translationLanguagePairsKey)
        restore(storedDefaultTranslationLanguagePairID, key: defaultTranslationLanguagePairIDKey)
        restore(storedLastUsedTranslationLanguagePairID, key: lastUsedTranslationLanguagePairIDKey)
        restore(storedTranslationTargetLanguages, key: translationTargetLanguagesKey)
        restore(storedVoiceTranslationTargetLanguage, key: voiceTranslationTargetLanguageKey)
        restore(storedTextTranslationSourceLanguage, key: textTranslationSourceLanguageKey)
        restore(storedTextTranslationTargetLanguage, key: textTranslationTargetLanguageKey)
        super.tearDown()
    }

    func test_defaultTranscriptionProvider_isCloud() {
        UserDefaults.standard.removeObject(forKey: transcriptionProviderKey)

        XCTAssertEqual(SettingsStorage.shared.transcriptionProvider, .cloud)
    }

    func test_explicitLocalTranscriptionProvider_isPreserved() {
        UserDefaults.standard.set(TranscriptionProvider.local.rawValue, forKey: transcriptionProviderKey)

        XCTAssertEqual(SettingsStorage.shared.transcriptionProvider, .local)
    }

    func test_defaultHistoryRetentionPolicies_areForever() {
        UserDefaults.standard.removeObject(forKey: dictationRetentionKey)
        UserDefaults.standard.removeObject(forKey: meetingRetentionKey)

        XCTAssertEqual(SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy, .forever)
        XCTAssertEqual(SettingsStorage.shared.meetingHistoryRetentionPolicy, .forever)
    }

    func test_explicitHistoryRetentionPolicies_arePreserved() {
        SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = .days30
        SettingsStorage.shared.meetingHistoryRetentionPolicy = .year1

        XCTAssertEqual(SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy, .days30)
        XCTAssertEqual(SettingsStorage.shared.meetingHistoryRetentionPolicy, .year1)
    }

    func test_invalidHistoryRetentionPolicy_fallsBackToForever() {
        UserDefaults.standard.set("invalid", forKey: dictationRetentionKey)
        UserDefaults.standard.set("invalid", forKey: meetingRetentionKey)

        XCTAssertEqual(SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy, .forever)
        XCTAssertEqual(SettingsStorage.shared.meetingHistoryRetentionPolicy, .forever)
    }

    func test_historyRetentionPolicy_routesRecordingTypesToExpectedBuckets() {
        SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = .days7
        SettingsStorage.shared.meetingHistoryRetentionPolicy = .days90

        XCTAssertEqual(SettingsStorage.shared.historyRetentionPolicy(for: .voice), .days7)
        XCTAssertEqual(SettingsStorage.shared.historyRetentionPolicy(for: .translation), .days7)
        XCTAssertEqual(SettingsStorage.shared.historyRetentionPolicy(for: .fileTranscription), .days7)
        XCTAssertEqual(SettingsStorage.shared.historyRetentionPolicy(for: .meeting), .days90)
        XCTAssertEqual(SettingsStorage.shared.historyRetentionPolicy(for: .meetingTranslation), .days90)
    }

    func test_keyboardLanguageDetector_prefersInputSourceLanguagesAndNormalizes() {
        let codes = KeyboardLanguageDetector.languageCodes(
            inputSourceLanguages: ["en-US", "uk-UA", "zz-ZZ", "EN"],
            inputSourceID: "com.apple.keylayout.French",
            localizedName: "French"
        )

        XCTAssertEqual(codes, ["en", "uk"])
    }

    func test_keyboardLanguageDetector_fallsBackToInputSourceMetadata() {
        XCTAssertEqual(
            KeyboardLanguageDetector.languageCodes(
                inputSourceLanguages: [],
                inputSourceID: "com.apple.keylayout.Ukrainian-PC",
                localizedName: "Ukrainian - PC"
            ),
            ["uk"]
        )
        XCTAssertEqual(
            KeyboardLanguageDetector.languageCodes(
                inputSourceLanguages: [],
                inputSourceID: "com.apple.keylayout.Unsupported",
                localizedName: "Unsupported"
            ),
            []
        )
    }

    func test_keyboardLanguageDetector_ignoresBloatedLanguagePropertyForKnownLayout() {
        let codes = KeyboardLanguageDetector.languageCodes(
            inputSourceLanguages: ["gl", "hi", "id", "it", "ms", "no", "pt", "sq", "sv"],
            inputSourceID: "com.apple.keylayout.US",
            localizedName: "U.S."
        )

        XCTAssertEqual(codes, ["en"])
    }

    func test_translationTargets_defaultFromLegacyPairAndFavoriteLanguages() {
        resetLanguageDefaults()
        UserDefaults.standard.set("en", forKey: translationLanguageAKey)
        UserDefaults.standard.set("uk", forKey: translationLanguageBKey)
        UserDefaults.standard.set(["en", "fr", "es"], forKey: favoriteLanguagesKey)

        XCTAssertEqual(SettingsStorage.shared.translationTargetLanguages, ["en", "uk", "fr", "es"])
        XCTAssertEqual(SettingsStorage.shared.voiceTranslationTargetLanguage, "uk")
    }

    func test_translationPairs_migrateFromLegacyPair() {
        resetLanguageDefaults()
        UserDefaults.standard.set("en-US", forKey: translationLanguageAKey)
        UserDefaults.standard.set("uk-UA", forKey: translationLanguageBKey)

        XCTAssertEqual(
            SettingsStorage.shared.translationLanguagePairs,
            [TranslationLanguagePair(languageA: "en", languageB: "uk")]
        )
        XCTAssertEqual(SettingsStorage.shared.defaultTranslationLanguagePair.displayLabel, "EN ⇄ UK")
    }

    func test_speechHints_mergeDetectedManualAndDisabledLanguages() {
        resetLanguageDefaults()
        SettingsStorage.shared.manualSpeechLanguageHints = ["fr", "EN", "invalid"]
        SettingsStorage.shared.disabledDetectedSpeechLanguageHints = ["pl"]

        let hints = SettingsStorage.shared.effectiveSpeechLanguageHints(
            detectedCodes: ["uk-UA", "pl-PL", "uk"]
        )

        XCTAssertEqual(hints, ["uk", "fr", "en"])
    }

    func test_translationPairResolver_usesKeyboardDefaultLastUsedAndFallbacks() {
        resetLanguageDefaults()
        let englishUkrainian = TranslationLanguagePair(languageA: "en", languageB: "uk")
        let englishPolish = TranslationLanguagePair(languageA: "en", languageB: "pl")
        let germanFrench = TranslationLanguagePair(languageA: "de", languageB: "fr")
        SettingsStorage.shared.translationLanguagePairs = [englishUkrainian, englishPolish, germanFrench]

        SettingsStorage.shared.defaultTranslationLanguagePairID = englishUkrainian.id
        SettingsStorage.shared.lastUsedTranslationLanguagePairID = englishPolish.id
        XCTAssertEqual(
            SettingsStorage.shared.resolveTranslationLanguagePair(currentKeyboardLanguage: "en-US"),
            englishUkrainian
        )

        SettingsStorage.shared.defaultTranslationLanguagePairID = germanFrench.id
        XCTAssertEqual(
            SettingsStorage.shared.resolveTranslationLanguagePair(currentKeyboardLanguage: "en-US"),
            englishPolish
        )

        SettingsStorage.shared.lastUsedTranslationLanguagePairID = nil
        XCTAssertEqual(
            SettingsStorage.shared.resolveTranslationLanguagePair(currentKeyboardLanguage: "en-US"),
            englishUkrainian
        )

        XCTAssertEqual(
            SettingsStorage.shared.resolveTranslationLanguagePair(currentKeyboardLanguage: "it-IT"),
            germanFrench
        )
    }

    func test_translationLanguageHints_includeSpeechHintsAndPairLanguages() {
        resetLanguageDefaults()
        SettingsStorage.shared.manualSpeechLanguageHints = ["pl"]
        SettingsStorage.shared.disabledDetectedSpeechLanguageHints = KeyboardLanguageDetector.detectedLanguageCodes()
        let pair = TranslationLanguagePair(languageA: "en", languageB: "uk")

        let hints = SettingsStorage.shared.translationLanguageHints(for: pair)

        XCTAssertEqual(hints, ["pl", "en", "uk"])
    }

    func test_cloudTranscriptionConfig_includesStrictLanguageHints() {
        let config = CloudTranscriptionService.makeTranscriptionConfig(
            languageConfig: CloudLanguageConfig(hints: ["en", "uk"], strict: false)
        )

        XCTAssertEqual(config["mode"] as? String, "transcribe")
        XCTAssertEqual(config["language_hints"] as? [String], ["en", "uk"])
        XCTAssertEqual(config["language_hints_strict"] as? Bool, true)
    }

    func test_cloudTwoWayTranslationConfig_includesPairAndStrictLanguageHints() {
        let pair = TranslationLanguagePair(languageA: "en", languageB: "uk")
        let config = CloudTranscriptionService.makeTwoWayTranslationConfig(
            languagePair: pair,
            languageConfig: CloudLanguageConfig(hints: ["pl", "en", "uk"], strict: true)
        )
        let translation = config["translation"] as? [String: Any]

        XCTAssertEqual(config["mode"] as? String, "translate")
        XCTAssertEqual(config["language_hints"] as? [String], ["pl", "en", "uk"])
        XCTAssertEqual(config["language_hints_strict"] as? Bool, true)
        XCTAssertEqual(translation?["type"] as? String, "two_way")
        XCTAssertEqual(translation?["language_a"] as? String, "en")
        XCTAssertEqual(translation?["language_b"] as? String, "uk")
    }

    func test_realtimeTranslationConfig_includesTwoWayPayloadAndStrictLanguageHints() {
        let config = CloudRealtimeService.makeConnectionConfig(
            languageHints: ["en", "uk"],
            strictLanguageHints: false,
            audioConfig: .defaultPCM16kMono,
            translationConfig: RealtimeTranslationConfig(mode: .twoWay(languageA: "en", languageB: "uk")),
            enableSpeakerDiarization: false
        )
        let translation = config["translation"] as? [String: Any]

        XCTAssertEqual(config["language_hints"] as? [String], ["en", "uk"])
        XCTAssertEqual(config["language_hints_strict"] as? Bool, true)
        XCTAssertEqual(translation?["type"] as? String, "two_way")
        XCTAssertEqual(translation?["language_a"] as? String, "en")
        XCTAssertEqual(translation?["language_b"] as? String, "uk")
    }

    func test_translationTargetSetterNormalizesAndAddsToShortlist() {
        UserDefaults.standard.set(["uk"], forKey: translationTargetLanguagesKey)
        UserDefaults.standard.removeObject(forKey: voiceTranslationTargetLanguageKey)

        SettingsStorage.shared.voiceTranslationTargetLanguage = " FR "

        XCTAssertEqual(SettingsStorage.shared.voiceTranslationTargetLanguage, "fr")
        XCTAssertEqual(SettingsStorage.shared.translationTargetLanguages, ["uk", "fr"])
    }

    func test_textTranslationSourceDefaultsToAutoAndAcceptsManualLanguage() {
        UserDefaults.standard.removeObject(forKey: textTranslationSourceLanguageKey)
        XCTAssertEqual(SettingsStorage.shared.textTranslationSourceLanguage, "auto")

        SettingsStorage.shared.textTranslationSourceLanguage = "ES"
        XCTAssertEqual(SettingsStorage.shared.textTranslationSourceLanguage, "es")

        SettingsStorage.shared.textTranslationSourceLanguage = "invalid"
        XCTAssertEqual(SettingsStorage.shared.textTranslationSourceLanguage, "auto")
    }

    @MainActor
    func test_textTranslationSwap_swapsLanguagesAndEditableText() {
        SettingsStorage.shared.translationTargetLanguages = ["en", "fr"]
        SettingsStorage.shared.textTranslationSourceLanguage = "en"
        SettingsStorage.shared.textTranslationTargetLanguage = "fr"

        let viewModel = TextTranslationViewModel(sourceText: "hello")
        viewModel.translatedText = "bonjour"

        viewModel.swapLanguagesAndText()

        XCTAssertEqual(viewModel.sourceText, "bonjour")
        XCTAssertEqual(viewModel.translatedText, "hello")
        XCTAssertEqual(viewModel.sourceLanguageCode, "fr")
        XCTAssertEqual(viewModel.targetLanguageCode, "en")
        XCTAssertEqual(SettingsStorage.shared.textTranslationSourceLanguage, "fr")
        XCTAssertEqual(SettingsStorage.shared.textTranslationTargetLanguage, "en")
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func resetLanguageDefaults() {
        [
            favoriteLanguagesKey,
            manualSpeechLanguageHintsKey,
            disabledDetectedSpeechLanguageHintsKey,
            translationLanguageAKey,
            translationLanguageBKey,
            translationLanguagePairsKey,
            defaultTranslationLanguagePairIDKey,
            lastUsedTranslationLanguagePairIDKey,
            translationTargetLanguagesKey,
            voiceTranslationTargetLanguageKey,
            textTranslationSourceLanguageKey,
            textTranslationTargetLanguageKey
        ].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}
