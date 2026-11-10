import Foundation

enum ProviderKeyStoreError: Error, Equatable {
    case emptyKey
    case keychainFailed
}

/// BYOK API keys, one Keychain item per provider. Keys are never logged and never put in error values.
final class ProviderKeyStore: @unchecked Sendable {
    static let shared: ProviderKeyStore = {
        #if DEBUG || TEST_BUILD
            if let backend = ProviderUITesting.keyBackend { return ProviderKeyStore(backend: backend) }
        #endif
        return ProviderKeyStore()
    }()

    private let backend: AuthTokenStore

    init(backend: AuthTokenStore = KeychainManager.shared) {
        self.backend = backend
    }

    static func account(for providerID: String) -> String {
        "byok.\(providerID).apiKey"
    }

    func save(_ key: String, for providerID: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderKeyStoreError.emptyKey }
        do {
            try backend.save(key: Self.account(for: providerID), value: trimmed)
        } catch {
            throw ProviderKeyStoreError.keychainFailed
        }
    }

    func key(for providerID: String) -> String? {
        backend.read(key: Self.account(for: providerID))
    }

    func hasKey(for providerID: String) -> Bool {
        key(for: providerID) != nil
    }

    /// Deletes the key and moves jobs that used this provider back to Diduny Cloud.
    /// Returns the affected jobs so the UI can name them. Pending remote deletes are not touched.
    @discardableResult
    func remove(for providerID: String, defaults: ProviderDefaultsStore) -> [STTJob] {
        delete(for: providerID)
        return defaults.resetJobs(using: providerID)
    }

    /// Deletes the key only; jobs keep their engine (a key that was just rejected on save).
    func delete(for providerID: String) {
        backend.delete(key: Self.account(for: providerID))
    }

    /// Shows at most the last 4 characters; short keys show none.
    func maskedKey(for providerID: String) -> String? {
        guard let key = key(for: providerID) else { return nil }
        return Self.mask(key)
    }

    static func mask(_ key: String) -> String {
        let visible = key.count > 8 ? String(key.suffix(4)) : ""
        return String(repeating: "•", count: 8) + visible
    }
}
