import Foundation
import Security

final class KeychainManager {
    static let shared = KeychainManager()

    private let serviceName = "ua.com.rmarinsky.diduny"

    private enum Key: String {
        case sonioxAPIKey = "soniox_api_key"
    }

    private var cachedKey: String?
    private var cacheLoaded = false

    private init() {}

    // MARK: - Soniox API Key

    /// Returns the API key, reading from Keychain only on first access (lazy cache).
    func getSonioxAPIKey() -> String? {
        if cacheLoaded {
            return cachedKey
        }
        cachedKey = get(key: .sonioxAPIKey)
        cacheLoaded = true
        SettingsStorage.shared.hasCloudAPIKey = (cachedKey?.isEmpty == false)
        return cachedKey
    }

    func setSonioxAPIKey(_ value: String) throws {
        try save(key: .sonioxAPIKey, value: value)
        cachedKey = value
        cacheLoaded = true
        SettingsStorage.shared.hasCloudAPIKey = true
    }

    func deleteSonioxAPIKey() throws {
        try delete(key: .sonioxAPIKey)
        cachedKey = nil
        cacheLoaded = true
        SettingsStorage.shared.hasCloudAPIKey = false
    }

    /// Lightweight check using UserDefaults flag — no Keychain access.
    func hasAPIKeyFast() -> Bool {
        SettingsStorage.shared.hasCloudAPIKey
    }

    /// Checks whether the app can read/write to the macOS Keychain.
    func isKeychainAccessible() -> Bool {
        let testKey = "keychain_access_check"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: testKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecItemNotFound means keychain is accessible but no item exists — that's fine
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private Methods

    private func save(key: Key, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.saveFailed
        }

        // Delete existing item first
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed
        }
    }

    private func get(key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return string
    }

    private func delete(key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed
        }
    }
}
