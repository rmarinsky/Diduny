import Foundation

/// Settings migration for the panels redesign (ADR-0012 D4, D5).
/// WP-14 adds only this type and its environment, so `SettingsStorage(defaults:migrationEnvironment:)`
/// exists for unit tests. WP-13 adds `runIfNeeded(defaults:environment:)` and the call in `init`.
enum SettingsMigration {
    struct Environment {
        let hasProviderKey: (String) -> Bool
        let isAppleSilicon: Bool

        /// The keychain is read only when a step asks for a key.
        static var live: Environment {
            Environment(
                hasProviderKey: { ProviderKeyStore.shared.hasKey(for: $0) },
                isAppleSilicon: ParakeetModelStore.isSupportedHardware
            )
        }
    }
}
