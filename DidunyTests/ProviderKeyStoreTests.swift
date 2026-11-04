@testable import Diduny
import XCTest

final class ProviderKeyStoreTests: XCTestCase {
    private final class FakeKeychain: AuthTokenStore, @unchecked Sendable {
        var items: [String: String] = [:]
        var failSave = false
        func save(key: String, value: String) throws {
            if failSave { throw KeychainError.saveFailed }
            items[key] = value
        }
        func read(key: String) -> String? { items[key] }
        func delete(key: String) { items[key] = nil }
    }

    private let sentinel = "sk_TEST_SENTINEL_0123456789"
    private var keychain: FakeKeychain!
    private var store: ProviderKeyStore!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        keychain = FakeKeychain()
        store = ProviderKeyStore(backend: keychain)
        suiteName = "diduny.provider-keys.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var defaultsStore: ProviderDefaultsStore {
        ProviderDefaultsStore(defaults: defaults, knownProviderIDs: [STTProviderID.didunyCloud, "elevenlabs", "other"])
    }

    func test_saveLoadOverwriteRemove_isolatedPerProvider() throws {
        try store.save(sentinel, for: "elevenlabs")
        try store.save("other-key", for: "other")
        XCTAssertEqual(store.key(for: "elevenlabs"), sentinel)
        try store.save("sk_new_value_9999", for: "elevenlabs")
        XCTAssertEqual(store.key(for: "elevenlabs"), "sk_new_value_9999")
        store.remove(for: "elevenlabs", defaults: defaultsStore)
        XCTAssertNil(store.key(for: "elevenlabs"))
        XCTAssertEqual(store.key(for: "other"), "other-key")
    }

    func test_persistsAcrossStoreInstances() throws {
        try store.save(sentinel, for: "elevenlabs")
        XCTAssertEqual(ProviderKeyStore(backend: keychain).key(for: "elevenlabs"), sentinel)
    }

    func test_maskShowsAtMostLast4() throws {
        try store.save(sentinel, for: "elevenlabs")
        let masked = try XCTUnwrap(store.maskedKey(for: "elevenlabs"))
        XCTAssertTrue(masked.hasSuffix("6789"))
        XCTAssertFalse(masked.contains("SENTINEL"))
        XCTAssertEqual(ProviderKeyStore.mask("abcd"), "••••••••")
    }

    func test_trimsWhitespaceAndRejectsEmpty() throws {
        try store.save("  \(sentinel)\n", for: "elevenlabs")
        XCTAssertEqual(store.key(for: "elevenlabs"), sentinel)
        XCTAssertThrowsError(try store.save("   \n", for: "elevenlabs")) {
            XCTAssertEqual($0 as? ProviderKeyStoreError, .emptyKey)
        }
    }

    func test_keyNeverInUserDefaultsOrErrors() throws {
        try store.save(sentinel, for: "elevenlabs")
        XCTAssertFalse(defaults.dictionaryRepresentation().description.contains(sentinel))
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().description.contains(sentinel))
        keychain.failSave = true
        XCTAssertThrowsError(try store.save(sentinel, for: "elevenlabs")) { error in
            XCTAssertEqual(error as? ProviderKeyStoreError, .keychainFailed)
            XCTAssertFalse(String(describing: error).contains(sentinel))
            XCTAssertFalse(error.localizedDescription.contains(sentinel))
        }
    }

    func test_removeResetsDefaultsAndReturnsAffectedJobs() throws {
        try store.save(sentinel, for: "elevenlabs")
        let eleven = JobProviderSelection(providerID: "elevenlabs", modelID: "scribe_v2_realtime")
        defaultsStore.setSelection(eleven, for: .dictation)
        defaultsStore.setSelection(eleven, for: .meeting)
        let affected = store.remove(for: "elevenlabs", defaults: defaultsStore)
        XCTAssertEqual(Set(affected), [.dictation, .meeting])
        for job in STTJob.allCases {
            XCTAssertEqual(defaultsStore.selection(for: job), .didunyCloud)
        }
    }

    func test_savingKeyDoesNotChangeDefaults() throws {
        try store.save(sentinel, for: "elevenlabs")
        for job in STTJob.allCases {
            XCTAssertEqual(defaultsStore.selection(for: job), .didunyCloud)
        }
    }

    func test_defaults_freshInstallIsCloud_perJobPersists_unknownFallsBack() {
        for job in STTJob.allCases {
            XCTAssertEqual(defaultsStore.selection(for: job), .didunyCloud)
        }
        let other = JobProviderSelection(providerID: "other", modelID: "m")
        defaultsStore.setSelection(other, for: .file)
        XCTAssertEqual(defaultsStore.selection(for: .file), other)
        XCTAssertEqual(defaultsStore.selection(for: .dictation), .didunyCloud)
        defaultsStore.setSelection(JobProviderSelection(providerID: "gone", modelID: nil), for: .meeting)
        XCTAssertEqual(defaultsStore.selection(for: .meeting), .didunyCloud)
    }
}
