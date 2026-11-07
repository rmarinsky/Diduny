@testable import Diduny
import Foundation
import Testing

/// WP-53: Settings > Languages and the Change popup (05 §2.3). Own `UserDefaults` suite per test.
@MainActor
final class LanguagesSettingsModelTests {
    private let suiteName = "LanguagesSettingsModelTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func model(detected: [String] = []) -> (LanguagesSettingsModel, SettingsStorage) {
        let store = SettingsStorage(defaults: defaults)
        return (LanguagesSettingsModel(store: store, detectedCodes: { detected }), store)
    }

    @Test("T5-LA-05 empty Languages you speak reads Detect the language and sends no hint")
    func emptySpeakSendsNoHint() {
        let (model, store) = model(detected: ["uk"])
        store.manualSpeechLanguageHints = []
        model.reload()
        #expect(model.speak == ["uk"])
        model.toggle("uk", in: .speak)
        #expect(model.speak.isEmpty)
        #expect(store.disabledDetectedSpeechLanguageHints.contains("uk"))
        #expect(store.effectiveSpeechLanguageHints(detectedCodes: ["uk"]).isEmpty)
        #expect(LanguagesSettingsModel.listText(model.speak) == String(localized: "Detect the language"))
    }

    @Test("T5-LA-05 ticks keep their order; a detected language is switched back on")
    func speakOrder() {
        let (model, store) = model(detected: ["uk"])
        store.manualSpeechLanguageHints = []
        model.toggle("uk", in: .speak)
        model.toggle("pl", in: .speak)
        model.toggle("de", in: .speak)
        #expect(store.manualSpeechLanguageHints == ["pl", "de"])
        model.toggle("uk", in: .speak)
        #expect(model.speak == ["uk", "pl", "de"])
        model.toggle("pl", in: .speak)
        #expect(store.manualSpeechLanguageHints == ["de"])
    }

    @Test("T5-LA-21 ticking Polish adds it to Your languages and its pairs")
    func tickYourLanguage() {
        let (model, store) = model()
        store.yourLanguages = ["en", "uk"]
        model.reload()
        model.toggle("pl", in: .yourLanguages)
        #expect(store.yourLanguages == ["en", "uk", "pl"])
        #expect(model.pairs.count == 3)
        #expect(model.targetOptions == ["en", "uk", "pl"])
    }

    @Test("T5-LA-22 the last of Your languages cannot be unticked")
    func lastLanguageStays() {
        let (model, store) = model()
        store.yourLanguages = ["en"]
        model.reload()
        #expect(!model.canToggle("en", in: .yourLanguages))
        model.toggle("en", in: .yourLanguages)
        #expect(store.yourLanguages == ["en"])
        #expect(model.pair == nil)
        #expect(model.canToggle("en", in: .speak))
    }

    @Test("T5-LA-24 and T5-LA-25 default target and pair are written to the store")
    func targetAndPair() {
        let (model, store) = model()
        store.yourLanguages = ["en", "uk", "pl"]
        model.reload()
        model.setDefaultTarget("pl")
        #expect(store.defaultTranslationTargetLanguage == "pl")
        model.selectPair(id: "en-pl")
        #expect(store.translationPair?.id == "en-pl")
        #expect(model.pair?.id == "en-pl")
    }

    @Test("T5-LA-26 voice command settings are written to the store")
    func voiceCommands() {
        let (model, store) = model()
        model.setVoiceCommandsEnabled(false)
        #expect(store.voiceTranslationCommandsEnabled == false)
        model.setVoicePosition(.anywhere)
        #expect(store.voiceTranslationCommandPosition == .anywhere)
        #expect(VoiceTranslationCommandPosition.allCases.map(\.displayName)
            == ["At the start and end", "At the end", "Anywhere"].map { String(localized: String.LocalizationValue($0)) })
    }

    @Test("T5-LA-27 popup rows: Chosen in order, All languages by name, search filters, Nothing found")
    func popupRows() {
        let names = ["en": "English", "uk": "Ukrainian", "pl": "Polish", "de": "German"]
        let name = { (code: String) in names[code] ?? code }
        let rows = ChangeLanguagesRows(chosen: ["uk", "en"], all: ["en", "uk", "pl", "de"], query: "", name: name)
        #expect(rows.chosen == ["uk", "en"])
        #expect(rows.rest == ["de", "pl"])
        let searched = ChangeLanguagesRows(chosen: ["uk", "en"], all: ["en", "uk", "pl", "de"], query: "pol", name: name)
        #expect(searched.chosen.isEmpty)
        #expect(searched.rest == ["pl"])
        #expect(ChangeLanguagesRows(chosen: ["en"], all: ["en", "pl"], query: "zzz", name: name).isEmpty)
    }
}
