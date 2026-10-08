import XCTest
@testable import Diduny

@MainActor
final class TranslationPairPickerControllerTests: XCTestCase {
    private var originalProvider: Any?
    private var originalSession: Any?

    override func setUp() {
        super.setUp()
        originalProvider = UserDefaults.standard.object(forKey: "translationProvider")
        originalSession = UserDefaults.standard.object(forKey: "_diduny_auth_session_present")
        SettingsStorage.shared.translationProvider = .cloud
        UserDefaults.standard.set(true, forKey: "_diduny_auth_session_present")
    }

    override func tearDown() {
        UserDefaults.standard.set(originalProvider, forKey: "translationProvider")
        UserDefaults.standard.set(originalSession, forKey: "_diduny_auth_session_present")
        super.tearDown()
    }

    func testLocalTranslationDoesNotOfferUnsupportedOutputLanguages() async {
        SettingsStorage.shared.translationProvider = .local
        let pairs = [
            TranslationLanguagePair(languageA: "en", languageB: "uk"),
            TranslationLanguagePair(languageA: "uk", languageB: "fr")
        ]
        let selection = Task {
            await TranslationPairPickerController.shared.pick(pairs: pairs, preselected: pairs[0])
        }
        await Task.yield()
        XCTAssertFalse(TranslationPairPickerController.shared.isVisible)
        TranslationPairPickerController.shared.confirmCurrentSelection()
        _ = await selection.value
    }

    func testPickShowsPickerForConfiguredPairs() async {
        let pairs = [
            TranslationLanguagePair(languageA: "uk", languageB: "en"),
            TranslationLanguagePair(languageA: "en", languageB: "es"),
        ]

        let selection = Task {
            await TranslationPairPickerController.shared.pick(
                pairs: pairs,
                preselected: pairs[0]
            )
        }
        await Task.yield()

        XCTAssertTrue(TranslationPairPickerController.shared.isVisible)
        TranslationPairPickerController.shared.confirmCurrentSelection()
        let selectedPair = await selection.value
        XCTAssertEqual(selectedPair, pairs[0])
    }
}
