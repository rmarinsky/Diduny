import Foundation

/// Settings migration for the panels redesign (ADR-0012 D4, D5).
/// WP-14 adds only this type and its environment, so `SettingsStorage(defaults:migrationEnvironment:)`
/// exists for unit tests. WP-13 adds `runIfNeeded(defaults:environment:)` and the call in `init`.
enum SettingsMigration {
    struct Environment {
        let hasProviderKey: (String) -> Bool
        let isAppleSilicon: Bool
        /// Keyboard-layout languages, read once to seed an unset "Your languages".
        var detectedKeyboardLanguages: () -> [String] = { [] }

        /// The keychain is read only when a step asks for a key.
        static var live: Environment {
            Environment(
                hasProviderKey: { ProviderKeyStore.shared.hasKey(for: $0) },
                isAppleSilicon: ParakeetModelStore.isSupportedHardware,
                detectedKeyboardLanguages: { KeyboardLanguageDetector.detectedLanguageCodes() }
            )
        }
    }

    static let schemaVersionKey = "settingsSchemaVersion"
    static let currentSchemaVersion = 4

    /// ADR-0012 D5: keys that only an earlier build writes before this migration runs.
    private static let existingInstallKeys = [
        "transcriptionProvider", "translationProvider", "pushToTalkKey", "autoPaste",
        "meetingRealtimeTranscriptionEnabled", "meetingLocalLivePreviewEnabled", "translationLanguagePairs",
        "onboarding.completed",
    ] + STTJob.allCases.map(ProviderDefaultsStore.storageKey(for:))

    static func isExistingInstall(_ defaults: UserDefaults) -> Bool {
        existingInstallKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// Runs once per install. Existing installs get the new keys from what runs today; fresh installs
    /// get nothing written (read-time defaults apply). Never deletes a legacy key.
    static func runIfNeeded(defaults: UserDefaults, environment: Environment) {
        let version = defaults.integer(forKey: schemaVersionKey)
        guard version < currentSchemaVersion else { return }
        seedYourLanguages(defaults: defaults, detected: environment.detectedKeyboardLanguages())
        if version == 2 || version == 3 {
            // Already ran the mode-defaults step before 8A: only the calendar mapping is new.
            if version == 2 { migrateCalendarLocalRecording(defaults: defaults) }
        } else if isExistingInstall(defaults) {
            migrateModeDefaults(defaults: defaults, environment: environment)
            migrateLanguages(defaults: defaults)
        }
        migrateRecordOnlyToWhisper(defaults: defaults)
        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
    }
}
