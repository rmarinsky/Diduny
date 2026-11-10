@testable import Diduny
import Foundation
import Testing

/// Roman 2026-11-10: the hints every engine gets come from "Your languages", never keyboard layouts.
/// Own `UserDefaults` suite per test.
final class SpeechLanguageHintsTests {
    private let suiteName = "SpeechLanguageHintsTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func storage(layouts: [String] = ["en", "uk"]) -> SettingsStorage {
        SettingsStorage(
            defaults: defaults,
            migrationEnvironment: .init(hasProviderKey: { _ in false }, isAppleSilicon: true,
                                        detectedKeyboardLanguages: { layouts })
        )
    }

    @Test("Layouts en+uk, Your languages [uk]: hints [uk], on-device uk")
    func singleLanguage() {
        let store = storage()
        store.yourLanguages = ["uk"]
        #expect(store.speechLanguageHints == ["uk"])
        #expect(OnDeviceLanguage.resolve(hints: store.speechLanguageHints) == "uk")
    }

    @Test("Your languages [uk, en]: hints in that order, on-device detects")
    func twoLanguages() {
        let store = storage()
        store.yourLanguages = ["uk", "en"]
        #expect(store.speechLanguageHints == ["uk", "en"])
        #expect(OnDeviceLanguage.resolve(hints: store.speechLanguageHints) == nil)
    }

    @Test("An explicit run or pair language wins over the list")
    func explicitWins() {
        let store = storage()
        store.yourLanguages = ["uk", "en"]
        #expect(OnDeviceLanguage.resolve(hints: store.speechLanguageHints, explicit: "en") == "en")
    }

    @Test("An unset list is seeded once from the layouts the person had not switched off, then their picks")
    func seededOnce() {
        defaults.set(["pl"], forKey: "disabledDetectedSpeechLanguageHints")
        defaults.set(["de"], forKey: "manualSpeechLanguageHints")
        let store = storage(layouts: ["uk-UA", "pl-PL", "en-US"])
        #expect(store.speechLanguageHints == ["uk", "en", "de"])

        store.yourLanguages = ["es"]
        let again = storage(layouts: ["uk"])
        #expect(again.speechLanguageHints == ["es"])
    }

    @Test("An emptied list stays empty across relaunch: no hint for cloud, nil on-device")
    @MainActor func emptiedStaysEmpty() {
        let store = storage()
        store.yourLanguages = []
        #expect(store.speechLanguageHints.isEmpty)
        defaults.removeObject(forKey: SettingsMigration.schemaVersionKey) // relaunch re-runs the migration
        let relaunched = storage(layouts: ["en", "uk"])
        #expect(relaunched.speechLanguageHints.isEmpty)
        #expect(RecordingQueueService.buildCloudTranscriptionConfig(
            hints: relaunched.speechLanguageHints, enableSpeakerDiarization: false
        )["language_hints"] == nil)
        #expect(OnDeviceLanguage.resolve(hints: relaunched.speechLanguageHints) == nil)
    }

    @Test("A stored list is never overwritten by the seed")
    func storedListKept() {
        defaults.set(["uk", "en", "es", "fr"], forKey: "yourLanguages")
        let store = storage(layouts: ["en", "uk"])
        #expect(store.speechLanguageHints == ["uk", "en", "es", "fr"])
    }
}
