@testable import Diduny
import Foundation
import Testing

/// 05 §4.3 / plan 6.4: every persona keeps the engine each mode runs today (T5-MIG-01 to 17, 32, 33, 35, 36).
@Suite("Settings migration")
struct SettingsMigrationTests {
    struct Persona: CustomTestStringConvertible {
        let fixture: String
        var hasKey = false
        var appleSilicon = true
        let dictation: EngineID
        let translation: EngineID
        let startsIn: MeetingSegment
        /// Engines of This Mac, Cloud and Record only.
        let segments: [EngineID]
        let meetingTranslation: EngineID
        let file: EngineID
        var testDescription: String { "\(fixture) key:\(hasKey) AS:\(appleSilicon)" }
    }

    static let personas: [Persona] = [
        Persona(fixture: "cloud-default", dictation: .didunyCloud, translation: .didunyCloud, startsIn: .cloud,
                segments: [.whisper, .didunyCloud, .parakeet], meetingTranslation: .didunyCloud, file: .whisper),
        // T5-MIG-02, 10: the old picker stored diduny-cloud for Local Whisper.
        Persona(fixture: "local-whisper-preview-on", dictation: .whisper, translation: .whisper, startsIn: .thisMac,
                segments: [.whisper, .didunyCloud, .parakeet], meetingTranslation: .didunyCloud, file: .whisper),
        // T5-MIG-11.
        Persona(fixture: "local-whisper-preview-off", dictation: .whisper, translation: .didunyCloud, startsIn: .recordOnly,
                segments: [.whisper, .didunyCloud, .whisper], meetingTranslation: .didunyCloud, file: .whisper),
        // T5-MIG-01, 05.
        Persona(fixture: "elevenlabs-meeting", hasKey: true, dictation: .elevenLabs, translation: .didunyCloud, startsIn: .cloud,
                segments: [.whisper, .elevenLabs, .parakeet], meetingTranslation: .didunyCloud, file: .whisper),
        // T5-MIG-06: without a key ElevenLabs never ran.
        Persona(fixture: "elevenlabs-meeting", dictation: .didunyCloud, translation: .didunyCloud, startsIn: .cloud,
                segments: [.whisper, .didunyCloud, .parakeet], meetingTranslation: .didunyCloud, file: .whisper),
        // T5-MIG-08.
        Persona(fixture: "parakeet-meeting", dictation: .didunyCloud, translation: .didunyCloud, startsIn: .recordOnly,
                segments: [.whisper, .didunyCloud, .parakeet], meetingTranslation: .didunyCloud, file: .whisper),
        // T5-MIG-07, 15.
        Persona(fixture: "apple-meeting", dictation: .didunyCloud, translation: .didunyCloud, startsIn: .thisMac,
                segments: [.appleSpeech, .didunyCloud, .appleSpeech], meetingTranslation: .appleSpeech, file: .whisper),
        // T5-MIG-16.
        Persona(fixture: "files-diduny-cloud", dictation: .didunyCloud, translation: .didunyCloud, startsIn: .cloud,
                segments: [.whisper, .didunyCloud, .parakeet], meetingTranslation: .didunyCloud, file: .whisper),
        Persona(fixture: "files-unset", dictation: .didunyCloud, translation: .didunyCloud, startsIn: .cloud,
                segments: [.whisper, .didunyCloud, .parakeet], meetingTranslation: .didunyCloud, file: .whisper),
        // T5-MIG-12: Intel gets Whisper for Record only.
        Persona(fixture: "cloud-default", appleSilicon: false, dictation: .didunyCloud, translation: .didunyCloud, startsIn: .cloud,
                segments: [.whisper, .didunyCloud, .whisper], meetingTranslation: .didunyCloud, file: .whisper),
        // T5-MIG-36.
        Persona(fixture: "roman-setup", hasKey: true, dictation: .didunyCloud, translation: .whisper, startsIn: .cloud,
                segments: [.whisper, .elevenLabs, .parakeet], meetingTranslation: .didunyCloud, file: .whisper),
    ]

    @Test("Each mode runs the same engine after the update", arguments: personas)
    func personaKeepsEngines(_ persona: Persona) throws {
        let (defaults, seed) = try Self.load(persona.fixture)
        Self.migrate(defaults, hasKey: persona.hasKey, appleSilicon: persona.appleSilicon)
        let modes = ModeDefaults(defaults: defaults)
        #expect(modes.engine(for: .dictation) == persona.dictation)
        #expect(modes.engine(for: .dictationTranslation) == persona.translation)
        #expect(modes.meetingStartsIn == persona.startsIn)
        #expect(MeetingSegment.allCases.map(modes.engine(for:)) == persona.segments)
        #expect(modes.engine(for: .meeting) == persona.segments[MeetingSegment.allCases.firstIndex(of: persona.startsIn)!])
        #expect(modes.engine(for: .meetingTranslation) == persona.meetingTranslation)
        #expect(modes.engine(for: .file) == persona.file)
        #expect(defaults.integer(forKey: SettingsMigration.schemaVersionKey) == SettingsMigration.currentSchemaVersion)
        Self.expectSeedUntouched(seed, in: defaults)
    }

    @Test("A second run changes nothing", arguments: personas)
    func idempotent(_ persona: Persona) throws {
        let (defaults, _) = try Self.load(persona.fixture)
        Self.migrate(defaults, hasKey: persona.hasKey, appleSilicon: persona.appleSilicon)
        let first = Self.snapshot(defaults)
        Self.migrate(defaults, hasKey: persona.hasKey, appleSilicon: persona.appleSilicon)
        #expect(Self.snapshot(defaults) == first)
        // Even with the version flag removed, the steps reach the same values.
        defaults.removeObject(forKey: SettingsMigration.schemaVersionKey)
        Self.migrate(defaults, hasKey: persona.hasKey, appleSilicon: persona.appleSilicon)
        #expect(Self.snapshot(defaults) == first)
    }

    @Test("Fresh install writes only the schema version and reads the new defaults (T5-MIG-17, T5-MD-08)")
    func freshInstall() throws {
        let (defaults, _) = try Self.load("fresh-install")
        Self.migrate(defaults, hasKey: false, appleSilicon: true)
        #expect(Self.snapshot(defaults) == [SettingsMigration.schemaVersionKey: "\(SettingsMigration.currentSchemaVersion)"])
        let modes = ModeDefaults(defaults: defaults)
        #expect(modes.engine(for: .dictation) == .didunyCloud)
        #expect(modes.engine(for: .dictationTranslation) == .didunyCloud)
        #expect(modes.meetingStartsIn == .cloud)
        #expect(MeetingSegment.allCases.map(modes.engine(for:)) == [.whisper, .didunyCloud, .parakeet])
        #expect(modes.engine(for: .meetingTranslation) == .didunyCloud)
        #expect(modes.engine(for: .file) == .parakeet)
        // Legacy readers keep "unset = Diduny Cloud" (ADR-0012 D4).
        #expect(ProviderDefaultsStore(defaults: defaults).selection(for: .file) == .didunyCloud)
    }

    @Test("The migration runs from SettingsStorage.init, before new-user defaults are written")
    func runsFromInit() throws {
        let (defaults, _) = try Self.load("fresh-install")
        let storage = SettingsStorage(defaults: defaults, migrationEnvironment: Self.environment(hasKey: false, appleSilicon: true))
        storage.applyNewUserDefaultsIfMissing()
        #expect(defaults.integer(forKey: SettingsMigration.schemaVersionKey) == SettingsMigration.currentSchemaVersion)
        #expect(defaults.object(forKey: ProviderDefaultsStore.storageKey(for: .file)) == nil)
        #expect(storage.modeDefaults.engine(for: .file) == .parakeet)
    }

    @Test("Keychain is asked only when ElevenLabs is stored")
    func keychainOnlyForElevenLabs() throws {
        var asked: [String] = []
        let (defaults, _) = try Self.load("local-whisper-preview-on")
        SettingsMigration.runIfNeeded(defaults: defaults, environment: .init(
            hasProviderKey: { asked.append($0); return true }, isAppleSilicon: true
        ))
        #expect(asked.isEmpty)
    }

    @Test("A stored ElevenLabs batch meeting model ran the legacy path, so it is not kept (ADR-0012 C8)")
    func elevenLabsBatchMeetingModel() throws {
        let (defaults, _) = try Self.load("cloud-default")
        ProviderDefaultsStore(defaults: defaults).setSelection(
            JobProviderSelection(providerID: STTProviderID.elevenLabs, modelID: ElevenLabsProvider.batchModelID), for: .meeting
        )
        Self.migrate(defaults, hasKey: true, appleSilicon: true)
        #expect(ModeDefaults(defaults: defaults).engine(for: .cloud) == .didunyCloud)
    }

    @Test("Parakeet meeting with the legacy Cloud flag keeps Cloud live, Record only Parakeet")
    func parakeetMeetingWithCloudFlag() throws {
        let (defaults, _) = try Self.load("parakeet-meeting")
        defaults.set(true, forKey: "meetingRealtimeTranscriptionEnabled")
        Self.migrate(defaults, hasKey: false, appleSilicon: true)
        let modes = ModeDefaults(defaults: defaults)
        #expect(modes.meetingStartsIn == .cloud)
        #expect(modes.engine(for: .cloud) == .didunyCloud)
        #expect(modes.engine(for: .recordOnly) == .parakeet)
    }

    @Test("Stored local-whisper meeting routes Local today whatever the flag says")
    func localWhisperMeetingSelection() throws {
        let (defaults, _) = try Self.load("cloud-default")
        ProviderDefaultsStore(defaults: defaults).setSelection(JobProviderSelection(providerID: STTProviderID.localWhisper), for: .meeting)
        Self.migrate(defaults, hasKey: false, appleSilicon: true)
        #expect(ModeDefaults(defaults: defaults).meetingStartsIn == .thisMac)
    }

    @Test("Unknown provider id migrates from the legacy value (T5-MIG-35)")
    func unknownProvider() throws {
        let (defaults, _) = try Self.load("cloud-default")
        defaults.set(try JSONEncoder().encode(JobProviderSelection(providerID: "foo")), forKey: "sttJobDefault.dictation")
        Self.migrate(defaults, hasKey: false, appleSilicon: true)
        #expect(ModeDefaults(defaults: defaults).engine(for: .dictation) == .didunyCloud)
    }

    @Test("Translate meeting and Files keep on-device choices (T5-MIG-15, 16)",
          arguments: [(EngineID.parakeet, EngineID.parakeet, EngineID.parakeet), (.appleSpeech, .appleSpeech, .appleSpeech),
                      (.elevenLabs, .didunyCloud, .whisper), (.didunyCloud, .didunyCloud, .whisper)])
    func onDeviceKept(stored: EngineID, translateMeeting: EngineID, file: EngineID) throws {
        let (defaults, _) = try Self.load("cloud-default")
        let store = ProviderDefaultsStore(defaults: defaults)
        store.setSelection(JobProviderSelection(providerID: stored.rawValue), for: .meetingTranslation)
        store.setSelection(JobProviderSelection(providerID: stored.rawValue), for: .file)
        Self.migrate(defaults, hasKey: true, appleSilicon: true)
        let modes = ModeDefaults(defaults: defaults)
        #expect(modes.engine(for: .meetingTranslation) == translateMeeting)
        #expect(modes.engine(for: .file) == file)
    }

    @Test("Silence values are copied to the split keys (05 §4.3 step 8)")
    func silenceCopied() throws {
        let (defaults, _) = try Self.load("silence-7-90")
        let storage = SettingsStorage(defaults: defaults, migrationEnvironment: Self.environment(hasKey: false, appleSilicon: true))
        #expect(defaults.double(forKey: "translationSilenceAutoStopSeconds") == 7)
        #expect(defaults.double(forKey: "meetingTranslationSilenceAutoStopSeconds") == 90)
        #expect(storage.translationSilenceAutoStopEnabled)
        #expect(!storage.meetingTranslationSilenceAutoStopEnabled)
        #expect(storage.meetingTranslationSilenceAutoStopSeconds == 90)
    }

    @Test("Languages run as a step (05 §4.3 step 7)")
    func languagesStep() throws {
        let (defaults, _) = try Self.load("pairs-en-uk-de-en")
        Self.migrate(defaults, hasKey: false, appleSilicon: true)
        #expect(defaults.stringArray(forKey: "yourLanguages") == ["en", "uk", "de"])
        #expect(defaults.string(forKey: "defaultTranslationTargetLanguage") == "uk")
    }

    @Test("A calendar that recorded on this Mac moves a Cloud start to This Mac; the field stays (8A, T5-MIG-13)",
          arguments: [(true, MeetingSegment.thisMac), (false, .cloud)])
    func calendarLocalRecording(local: Bool, expected: MeetingSegment) throws {
        let (defaults, _) = try Self.load("cloud-default")
        var calendar = CalendarConfiguration()
        calendar.localRecording = local
        let blob = try JSONEncoder().encode(calendar)
        defaults.set(blob, forKey: "calendar.connection.v1")
        Self.migrate(defaults, hasKey: false, appleSilicon: true)
        #expect(ModeDefaults(defaults: defaults).meetingStartsIn == expected)
        #expect(defaults.data(forKey: "calendar.connection.v1") == blob)
    }

    @Test("Schema 2 to 3 runs only the calendar mapping", arguments: [(true, MeetingSegment.thisMac), (false, .cloud)])
    func schemaTwoToThree(local: Bool, expected: MeetingSegment) throws {
        let (defaults, _) = try Self.load("cloud-default")
        defaults.set(2, forKey: SettingsMigration.schemaVersionKey)
        defaults.set(MeetingSegment.cloud.rawValue, forKey: ModeDefaults.meetingTranscriptModeKey)
        var calendar = CalendarConfiguration()
        calendar.localRecording = local
        defaults.set(try JSONEncoder().encode(calendar), forKey: "calendar.connection.v1")
        let before = Self.snapshot(defaults).filter { $0.key != ModeDefaults.meetingTranscriptModeKey && $0.key != SettingsMigration.schemaVersionKey }
        Self.migrate(defaults, hasKey: false, appleSilicon: true)
        #expect(ModeDefaults(defaults: defaults).meetingStartsIn == expected)
        #expect(defaults.integer(forKey: SettingsMigration.schemaVersionKey) == 3)
        let after = Self.snapshot(defaults).filter { $0.key != ModeDefaults.meetingTranscriptModeKey && $0.key != SettingsMigration.schemaVersionKey }
        #expect(after == before)
    }

    @Test("No saved calendar: Starts in is unchanged")
    func noCalendar() throws {
        let (defaults, _) = try Self.load("cloud-default")
        Self.migrate(defaults, hasKey: false, appleSilicon: true)
        #expect(ModeDefaults(defaults: defaults).meetingStartsIn == .cloud)
    }

    // MARK: - Helpers

    static func environment(hasKey: Bool, appleSilicon: Bool) -> SettingsMigration.Environment {
        .init(hasProviderKey: { _ in hasKey }, isAppleSilicon: appleSilicon)
    }

    static func migrate(_ defaults: UserDefaults, hasKey: Bool, appleSilicon: Bool) {
        SettingsMigration.runIfNeeded(defaults: defaults, environment: environment(hasKey: hasKey, appleSilicon: appleSilicon))
    }

    /// Loads `Fixtures/settings/<name>.plist` into a fresh suite. Read from the source tree so the plists
    /// need no bundle resource phase.
    static func load(_ name: String) throws -> (UserDefaults, [String: Any]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/settings/\(name).plist")
        let seed = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let suite = "test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        seed.forEach { defaults.set($1, forKey: $0) }
        return (defaults, seed)
    }

    /// Only the suite's own keys: global-domain keys are dropped by comparing with an empty suite.
    static func snapshot(_ defaults: UserDefaults) -> [String: String] {
        let suite = "test.empty.\(UUID().uuidString)"
        let baseline = UserDefaults(suiteName: suite)!.dictionaryRepresentation()
        return defaults.dictionaryRepresentation()
            .filter { baseline[$0.key] == nil }
            .mapValues { "\($0)" }
    }

    static func expectSeedUntouched(_ seed: [String: Any], in defaults: UserDefaults) {
        for (key, value) in seed where !key.hasPrefix("sttJobDefault.") || key == "sttJobDefault.meeting" {
            #expect((defaults.object(forKey: key) as? NSObject) == (value as? NSObject), "\(key)")
        }
    }
}
