import Foundation

/// 05 §4.3 steps 1-5 and 8 (plan 3.6 steps 1-5, 7): each mode keeps the engine it runs today.
/// Writes only mode-default keys; reads legacy keys raw, through today's implicit defaults (ADR-0012 C13).
extension SettingsMigration {
    private enum LegacyKey: String {
        case transcriptionProvider
        case translationProvider
        case meetingRealtimeTranscriptionEnabled
        case meetingLocalLivePreviewEnabled
        case dictationSilenceAutoStopEnabled
        case dictationSilenceAutoStopSeconds
        case meetingSilenceAutoStopEnabled
        case meetingSilenceAutoStopSeconds
        case translationSilenceAutoStopEnabled
        case translationSilenceAutoStopSeconds
        case meetingTranslationSilenceAutoStopEnabled
        case meetingTranslationSilenceAutoStopSeconds
    }

    static func migrateModeDefaults(defaults: UserDefaults, environment: Environment) {
        let store = ProviderDefaultsStore(defaults: defaults)
        let transcriptionLocal = defaults.string(forKey: LegacyKey.transcriptionProvider.rawValue)
            == TranscriptionProvider.local.rawValue
        let translationLocal = defaults.string(forKey: LegacyKey.translationProvider.rawValue)
            == TranscriptionProvider.local.rawValue

        migrateDictationJob(.dictation, legacyLocal: transcriptionLocal, store: store, environment: environment)
        migrateDictationJob(.dictationTranslation, legacyLocal: translationLocal, store: store, environment: environment)
        migrateMeeting(defaults: defaults, store: store, transcriptionLocal: transcriptionLocal, environment: environment)
        keepOnDevice(.meetingTranslation, else: .didunyCloud, store: store)
        keepOnDevice(.file, else: .whisper, store: store)
        copySilence(defaults: defaults)
    }

    /// Steps 1-2. Parakeet, Apple, Whisper and ElevenLabs with a key run today when stored; else the raw legacy value.
    private static func migrateDictationJob(
        _ job: STTJob, legacyLocal: Bool, store: ProviderDefaultsStore, environment: Environment
    ) {
        let stored = store.storedSelection(forKey: ProviderDefaultsStore.storageKey(for: job))
        switch stored.flatMap({ EngineID(rawValue: $0.providerID) }) {
        case .parakeet, .appleSpeech, .whisper: return
        case .elevenLabs where environment.hasProviderKey(STTProviderID.elevenLabs): return
        default:
            store.setSelection(selection(legacyLocal ? .whisper : .didunyCloud), for: job)
        }
    }

    /// Step 3: "Starts in" and the three segment engines from what a meeting runs today.
    private static func migrateMeeting(
        defaults: UserDefaults, store: ProviderDefaultsStore, transcriptionLocal: Bool, environment: Environment
    ) {
        let legacyCloud = defaults.object(forKey: LegacyKey.meetingRealtimeTranscriptionEnabled.rawValue) == nil
            ? !transcriptionLocal
            : defaults.bool(forKey: LegacyKey.meetingRealtimeTranscriptionEnabled.rawValue)
        let preview = defaults.object(forKey: LegacyKey.meetingLocalLivePreviewEnabled.rawValue) == nil
            || defaults.bool(forKey: LegacyKey.meetingLocalLivePreviewEnabled.rawValue)
        let stored = store.storedSelection(forKey: ProviderDefaultsStore.storageKey(for: .meeting))

        var segments: [MeetingSegment: JobProviderSelection] = [
            .thisMac: selection(.whisper),
            .cloud: selection(.didunyCloud),
            .recordOnly: selection(environment.isAppleSilicon ? .parakeet : .whisper),
        ]
        var startsIn: MeetingSegment
        switch stored.flatMap({ EngineID(rawValue: $0.providerID) }) {
        case .elevenLabs where environment.hasProviderKey(STTProviderID.elevenLabs)
            && stored?.modelID == ElevenLabsProvider.realtimeModelID:
            // The only case where a meeting runs ElevenLabs today (ADR-0012 C8).
            startsIn = .cloud
            segments[.cloud] = stored
        case .appleSpeech:
            // Apple streams live on this Mac and also makes the after-Stop transcript.
            startsIn = .thisMac
            segments[.thisMac] = stored
            segments[.recordOnly] = stored
        case .parakeet:
            // Parakeet makes the transcript after Stop. With the legacy Cloud flag on, today's meeting is
            // still Diduny Cloud live, so Starts in stays Cloud and only Record only keeps Parakeet.
            startsIn = legacyCloud ? .cloud : .recordOnly
            segments[.recordOnly] = stored
        default:
            // Legacy Cloud/Local; a stored `local-whisper` routes Local today whatever the flag says.
            let local = !legacyCloud || stored?.providerID == STTProviderID.localWhisper
            if !local {
                startsIn = .cloud
            } else if preview {
                startsIn = .thisMac
            } else {
                startsIn = .recordOnly
                segments[.recordOnly] = selection(.whisper)
            }
        }

        // 8A: calendar meetings now follow "Starts in". A calendar that recorded on this Mac moves a Cloud
        // start to This Mac, so no meeting that ran on this Mac starts going to the cloud.
        if startsIn == .cloud, calendarRecordedLocally(defaults) { startsIn = .thisMac }

        // The segments the row decides are written; the others only when unset.
        var decided: Set<MeetingSegment> = [startsIn]
        if case .appleSpeech? = stored.flatMap({ EngineID(rawValue: $0.providerID) }) { decided.insert(.recordOnly) }
        if case .parakeet? = stored.flatMap({ EngineID(rawValue: $0.providerID) }) { decided.insert(.recordOnly) }
        for segment in MeetingSegment.allCases {
            let key = ModeDefaults.storageKey(for: segment)
            guard let value = segments[segment],
                  decided.contains(segment) || store.storedSelection(forKey: key) == nil else { continue }
            store.setSelection(value, forKey: key)
        }
        ModeDefaults(defaults: defaults).apply([.startsIn(startsIn)])
    }

    /// Schema 3 for installs already at 2: the same calendar mapping, nothing else.
    static func migrateCalendarLocalRecording(defaults: UserDefaults) {
        let modes = ModeDefaults(defaults: defaults)
        if modes.meetingStartsIn == .cloud, calendarRecordedLocally(defaults) { modes.apply([.startsIn(.thisMac)]) }
    }

    /// The saved calendar connection with `localRecording` on (missing key: the old default, on).
    /// The field stays in the blob; it is only read here.
    private static func calendarRecordedLocally(_ defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: "calendar.connection.v1"),
              let saved = try? JSONDecoder().decode(CalendarConfiguration.self, from: data) else { return false }
        return saved.localRecording
    }

    /// Steps 4-5: keep Parakeet or Apple; anything else is what runs today, `fallback`.
    private static func keepOnDevice(_ job: STTJob, else fallback: EngineID, store: ProviderDefaultsStore) {
        let id = store.storedSelection(forKey: ProviderDefaultsStore.storageKey(for: job))?.providerID
        guard id.map(STTProviderID.onDeviceEngines.contains) != true else { return }
        store.setSelection(selection(fallback), for: job)
    }

    /// 05 §4.3 step 8 (Q5 default): the split keys start from the shared values.
    private static func copySilence(defaults: UserDefaults) {
        let pairs: [(LegacyKey, LegacyKey)] = [
            (.dictationSilenceAutoStopEnabled, .translationSilenceAutoStopEnabled),
            (.dictationSilenceAutoStopSeconds, .translationSilenceAutoStopSeconds),
            (.meetingSilenceAutoStopEnabled, .meetingTranslationSilenceAutoStopEnabled),
            (.meetingSilenceAutoStopSeconds, .meetingTranslationSilenceAutoStopSeconds),
        ]
        for (source, target) in pairs where defaults.object(forKey: target.rawValue) == nil {
            if let value = defaults.object(forKey: source.rawValue) {
                defaults.set(value, forKey: target.rawValue)
            }
        }
    }

    private static func selection(_ engine: EngineID) -> JobProviderSelection {
        JobProviderSelection(providerID: engine.rawValue, modelID: nil)
    }
}
