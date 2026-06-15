@testable import Diduny
import XCTest

final class SettingsStorageProviderTests: XCTestCase {
    private let transcriptionProviderKey = "transcriptionProvider"
    private let dictationRetentionKey = "dictationTranslationHistoryRetentionPolicy"
    private let meetingRetentionKey = "meetingHistoryRetentionPolicy"
    private var storedProvider: Any?
    private var storedDictationRetention: Any?
    private var storedMeetingRetention: Any?

    override func setUp() {
        super.setUp()
        storedProvider = UserDefaults.standard.object(forKey: transcriptionProviderKey)
        storedDictationRetention = UserDefaults.standard.object(forKey: dictationRetentionKey)
        storedMeetingRetention = UserDefaults.standard.object(forKey: meetingRetentionKey)
    }

    override func tearDown() {
        restore(storedProvider, key: transcriptionProviderKey)
        restore(storedDictationRetention, key: dictationRetentionKey)
        restore(storedMeetingRetention, key: meetingRetentionKey)
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

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
