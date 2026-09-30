@testable import Diduny
import XCTest

final class SettingsStorageTTSKeysTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let voiceIDKey = "ttsSelectedVoiceID"
    private let modelTierKey = "ttsModelTier"
    private let speedKey = "ttsSpeed"

    private var storedVoiceID: Any?
    private var storedModelTier: Any?
    private var storedSpeed: Any?

    override func setUp() {
        super.setUp()
        storedVoiceID = defaults.object(forKey: voiceIDKey)
        storedModelTier = defaults.object(forKey: modelTierKey)
        storedSpeed = defaults.object(forKey: speedKey)
        defaults.removeObject(forKey: voiceIDKey)
        defaults.removeObject(forKey: modelTierKey)
        defaults.removeObject(forKey: speedKey)
    }

    override func tearDown() {
        restore(storedVoiceID, key: voiceIDKey)
        restore(storedModelTier, key: modelTierKey)
        restore(storedSpeed, key: speedKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func test_speechIsGroupedWithSettingsNavigation() {
        XCTAssertTrue(MainSection.settingsItems.contains(.speech))
        XCTAssertFalse(MainSection.mainItems.contains(.speech))
    }

    func test_selectedVoiceID_defaultsToNilAndRoundTrips() {
        XCTAssertNil(SettingsStorage.shared.ttsSelectedVoiceID)

        SettingsStorage.shared.ttsSelectedVoiceID = "fbb75ed2-975a-40c7-9e06-38e30524a9a1"
        XCTAssertEqual(SettingsStorage.shared.ttsSelectedVoiceID, "fbb75ed2-975a-40c7-9e06-38e30524a9a1")

        SettingsStorage.shared.ttsSelectedVoiceID = ""
        XCTAssertNil(SettingsStorage.shared.ttsSelectedVoiceID, "empty string is normalized to nil")
    }

    func test_modelTier_defaultsToQualityAndRoundTrips() {
        XCTAssertEqual(SettingsStorage.shared.ttsModelTier, .quality)

        SettingsStorage.shared.ttsModelTier = .fast
        XCTAssertEqual(SettingsStorage.shared.ttsModelTier, .fast)

        defaults.set("bogus", forKey: modelTierKey)
        XCTAssertEqual(SettingsStorage.shared.ttsModelTier, .quality, "unknown raw value falls back")
    }

    func test_speed_defaultsToOneAndRoundTrips() {
        XCTAssertEqual(SettingsStorage.shared.ttsSpeed, 1.0, accuracy: 0.0001)

        SettingsStorage.shared.ttsSpeed = 1.45
        XCTAssertEqual(SettingsStorage.shared.ttsSpeed, 1.45, accuracy: 0.0001)

        defaults.removeObject(forKey: speedKey)
        XCTAssertEqual(SettingsStorage.shared.ttsSpeed, 1.0, accuracy: 0.0001, "unset speed reads as 1.0")
    }

    func test_defaultsRegistration_setsTTSValuesWithoutOverwriting() {
        defaults.removeObject(forKey: modelTierKey)
        defaults.removeObject(forKey: speedKey)
        defaults.set(1.8, forKey: speedKey)

        SettingsStorage.shared.applyNewUserDefaultsIfMissing()

        XCTAssertEqual(defaults.string(forKey: modelTierKey), "quality")
        XCTAssertEqual(defaults.double(forKey: speedKey), 1.8, accuracy: 0.0001, "persisted value is preserved")
    }
}
