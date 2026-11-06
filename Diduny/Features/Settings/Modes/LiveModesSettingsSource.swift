import Foundation

/// `ModesSettingsSource` over today's settings. Interim until WP-13 lands `ModeDefaults`:
/// - the new keys use the ADR-0012 D4 names and formats, so WP-13 reads what this writes;
/// - engine writes go through `EngineOptions.apply`, which also writes the legacy keys today's recording
///   flows read, so a pick in Modes keeps working before WP-17 moves routing to the new keys.
@MainActor
final class LiveModesSettingsSource: ModesSettingsSource {
    private enum ModesKey: String {
        case meetingTranscriptMode
        case dictationTranslationTargetLanguage
        case meetingTranslationShowOriginal
    }

    private let storage: SettingsStorage
    private let isAppleSilicon: Bool
    private let notifications: NotificationCenter

    init(
        storage: SettingsStorage = .shared,
        isAppleSilicon: Bool = ParakeetModelStore.isSupportedHardware,
        notifications: NotificationCenter = .default
    ) {
        self.storage = storage
        self.isAppleSilicon = isAppleSilicon
        self.notifications = notifications
    }

    private var defaults: UserDefaults { storage.defaults }
    private var providerDefaults: ProviderDefaultsStore { storage.providerDefaults }
    private var localDefault: EngineID { isAppleSilicon ? .parakeet : .whisper }

    // MARK: Engines

    func engine(for job: STTJob) -> EngineID {
        let stored = providerDefaults.selection(for: job)
        let engine = EngineID(rawValue: stored.providerID) ?? .didunyCloud
        switch job {
        case .dictation:
            return engine == .didunyCloud && storage.transcriptionProvider == .local ? .whisper : engine
        case .dictationTranslation:
            return engine == .didunyCloud && storage.translationProvider == .local ? .whisper : engine
        case .file:
            // Files runs on this Mac only (decision 4); unset reads Parakeet V3, a cloud value runs Whisper today (F2).
            guard defaults.object(forKey: ProviderDefaultsStore.storageKey(for: .file)) != nil else { return localDefault }
            return engine == .didunyCloud || engine == .elevenLabs ? .whisper : engine
        case .meeting:
            return meetingEngine(for: meetingStartsIn)
        case .meetingTranslation:
            return engine
        }
    }

    func setEngine(_ engine: EngineID, for job: STTJob) {
        guard job != .meeting else { return setMeetingEngine(engine, for: meetingStartsIn) }
        if job == .file {
            providerDefaults.setSelection(JobProviderSelection(providerID: engine.rawValue, modelID: nil), for: .file)
            return
        }
        EngineOptions.apply(Self.optionID(engine, job: job, segment: nil), job: job) { [storage] isLocal in
            switch job {
            case .dictation: storage.transcriptionProvider = isLocal ? .local : .cloud
            case .dictationTranslation: storage.translationProvider = isLocal ? .local : .cloud
            default: break
            }
        }
    }

    var meetingStartsIn: MeetingSegment {
        get {
            if let raw = defaults.string(forKey: ModesKey.meetingTranscriptMode.rawValue),
               let segment = MeetingSegment(rawValue: raw) { return segment }
            if storage.meetingRealtimeTranscriptionEnabled { return .cloud }
            return storage.meetingLocalLivePreviewEnabled ? .thisMac : .recordOnly
        }
        set {
            defaults.set(newValue.rawValue, forKey: ModesKey.meetingTranscriptMode.rawValue)
            mirrorLegacyMeeting()
        }
    }

    func meetingEngine(for segment: MeetingSegment) -> EngineID {
        if let data = defaults.data(forKey: Self.segmentKey(segment)),
           let selection = try? JSONDecoder().decode(JobProviderSelection.self, from: data),
           let engine = EngineID(rawValue: selection.providerID) { return engine }
        switch segment {
        case .thisMac: return .whisper
        case .cloud: return .didunyCloud
        case .recordOnly: return localDefault
        }
    }

    func setMeetingEngine(_ engine: EngineID, for segment: MeetingSegment) {
        let selection = JobProviderSelection(providerID: engine.rawValue, modelID: Self.modelID(engine, job: .meeting, segment: segment))
        if let data = try? JSONEncoder().encode(selection) { defaults.set(data, forKey: Self.segmentKey(segment)) }
        if segment == meetingStartsIn { mirrorLegacyMeeting() }
    }

    /// Today's meeting flow reads `sttJobDefault.meeting`, `meetingRealtimeTranscriptionEnabled` and the live
    /// preview switch. Write what makes it run the current segment, as the old Meeting picker did.
    private func mirrorLegacyMeeting() {
        let segment = meetingStartsIn
        let engine = meetingEngine(for: segment)
        let runsOnThisMac = ProviderRegistry.shared.module(id: engine.rawValue)?.traits.runsOn == .thisMac
        if segment == .recordOnly, !runsOnThisMac {
            // Record only with a cloud engine has no legacy form (WP-62 wires it): keep the audio local.
            storage.meetingRealtimeTranscriptionEnabled = false
            providerDefaults.setSelection(.didunyCloud, for: .meeting)
        } else {
            EngineOptions.apply(Self.optionID(engine, job: .meeting, segment: segment), job: .meeting) { [storage] isLocal in
                storage.meetingRealtimeTranscriptionEnabled = !isLocal
            }
        }
        storage.meetingLocalLivePreviewEnabled = segment == .thisMac
    }

    /// `EngineOptions.apply` id: the engine id, or "<provider>/<model>" for a key engine.
    private static func optionID(_ engine: EngineID, job: STTJob, segment: MeetingSegment?) -> String {
        guard let model = modelID(engine, job: job, segment: segment) else { return engine.rawValue }
        return "\(engine.rawValue)/\(model)"
    }

    /// ADR-0012 D6: ElevenLabs stores the realtime model where it runs live, the batch model after Stop.
    /// WP-13's `ModeEngineRules.modelID(engine:job:segment:)` replaces this.
    private static func modelID(_ engine: EngineID, job: STTJob, segment: MeetingSegment?) -> String? {
        guard engine == .elevenLabs else { return nil }
        switch job {
        case .dictation, .dictationTranslation: return ElevenLabsProvider.realtimeModelID
        case .meeting: return segment == .cloud ? ElevenLabsProvider.realtimeModelID : ElevenLabsProvider.batchModelID
        case .meetingTranslation, .file: return ElevenLabsProvider.batchModelID
        }
    }

    private static func segmentKey(_ segment: MeetingSegment) -> String {
        "\(ProviderDefaultsStore.storageKey(for: .meeting)).\(segment.rawValue)"
    }

    // MARK: Languages

    var dictationTranslationTarget: String {
        get { defaults.string(forKey: ModesKey.dictationTranslationTargetLanguage.rawValue) ?? storage.defaultTranslationTargetLanguage }
        set { defaults.set(newValue, forKey: ModesKey.dictationTranslationTargetLanguage.rawValue) }
    }

    var yourLanguages: [String] { storage.yourLanguages }
    var translationPair: TranslationLanguagePair? { storage.translationPair }
    var offeredTranslationPairs: [TranslationLanguagePair] { storage.offeredTranslationPairs }
    func selectTranslationPair(_ pair: TranslationLanguagePair) { storage.selectTranslationPair(pair) }

    // MARK: Options

    var meetingTranslationShowOriginal: Bool {
        get { defaults.bool(forKey: ModesKey.meetingTranslationShowOriginal.rawValue) }
        set { defaults.set(newValue, forKey: ModesKey.meetingTranslationShowOriginal.rawValue) }
    }

    var meetingSuggestionsEnabled: Bool {
        get { storage.meetingSuggestionsEnabled }
        set { storage.meetingSuggestionsEnabled = newValue }
    }

    func pushToTalk(for job: STTJob) -> ModePushToTalk {
        job == .dictationTranslation
            ? ModePushToTalk(
                key: storage.translationPushToTalkKey,
                toggleEnabled: storage.translationPushToTalkToggleEnabled,
                tapCount: storage.translationPushToTalkToggleTapCount,
                holdEnabled: storage.translationPushToTalkHoldEnabled,
                holdDelaySeconds: storage.translationPushToTalkHoldStartDelaySeconds
            )
            : ModePushToTalk(
                key: storage.pushToTalkKey,
                toggleEnabled: storage.pushToTalkToggleEnabled,
                tapCount: storage.pushToTalkToggleTapCount,
                holdEnabled: storage.pushToTalkHoldEnabled,
                holdDelaySeconds: storage.pushToTalkHoldStartDelaySeconds
            )
    }

    /// Writes only what changed and posts the notification `PushToTalkService` listens to, as Shortcuts does.
    func setPushToTalk(_ value: ModePushToTalk, for job: STTJob) {
        let old = pushToTalk(for: job)
        let translation = job == .dictationTranslation
        if value.key != old.key {
            if translation { storage.translationPushToTalkKey = value.key } else { storage.pushToTalkKey = value.key }
            notifications.post(name: translation ? .translationPushToTalkKeyChanged : .pushToTalkKeyChanged, object: value.key)
        }
        if value.toggleEnabled != old.toggleEnabled || value.holdEnabled != old.holdEnabled {
            if translation {
                storage.translationPushToTalkToggleEnabled = value.toggleEnabled
                storage.translationPushToTalkHoldEnabled = value.holdEnabled
            } else {
                storage.pushToTalkToggleEnabled = value.toggleEnabled
                storage.pushToTalkHoldEnabled = value.holdEnabled
            }
            notifications.post(name: translation ? .translationPushToTalkModeChanged : .pushToTalkModeChanged, object: nil)
        }
        if value.tapCount != old.tapCount {
            if translation { storage.translationPushToTalkToggleTapCount = value.tapCount } else { storage.pushToTalkToggleTapCount = value.tapCount }
            notifications.post(name: translation ? .translationPushToTalkTapCountChanged : .pushToTalkTapCountChanged, object: value.tapCount)
        }
        if value.holdDelaySeconds != old.holdDelaySeconds {
            if translation {
                storage.translationPushToTalkHoldStartDelaySeconds = value.holdDelaySeconds
            } else {
                storage.pushToTalkHoldStartDelaySeconds = value.holdDelaySeconds
            }
            notifications.post(
                name: translation ? .translationPushToTalkHoldStartDelayChanged : .pushToTalkHoldStartDelayChanged,
                object: value.holdDelaySeconds
            )
        }
    }

    /// One key pair per kind today: Translation shares Dictation's, Translate meeting shares Meeting's.
    /// WP-13 splits them into four (05 Q5 default); then this reads its keys.
    func silence(for job: STTJob) -> ModeSilence {
        Self.isMeetingKind(job)
            ? ModeSilence(enabled: storage.meetingSilenceAutoStopEnabled, seconds: storage.meetingSilenceAutoStopSeconds)
            : ModeSilence(enabled: storage.dictationSilenceAutoStopEnabled, seconds: storage.dictationSilenceAutoStopSeconds)
    }

    func setSilence(_ value: ModeSilence, for job: STTJob) {
        if Self.isMeetingKind(job) {
            storage.meetingSilenceAutoStopEnabled = value.enabled
            storage.meetingSilenceAutoStopSeconds = value.seconds
        } else {
            storage.dictationSilenceAutoStopEnabled = value.enabled
            storage.dictationSilenceAutoStopSeconds = value.seconds
        }
    }

    private static func isMeetingKind(_ job: STTJob) -> Bool {
        job == .meeting || job == .meetingTranslation
    }

    func pressCount(for job: STTJob) -> Int {
        switch job {
        case .dictation: storage.recordingHotkeyPressCount
        case .dictationTranslation: storage.translationHotkeyPressCount
        case .meeting: storage.meetingHotkeyPressCount
        case .meetingTranslation: storage.meetingTranslationHotkeyPressCount
        case .file: 1
        }
    }

    func setPressCount(_ count: Int, for job: STTJob) {
        switch job {
        case .dictation: storage.recordingHotkeyPressCount = count
        case .dictationTranslation: storage.translationHotkeyPressCount = count
        case .meeting: storage.meetingHotkeyPressCount = count
        case .meetingTranslation: storage.meetingTranslationHotkeyPressCount = count
        case .file: break
        }
    }
}

/// Interim readiness for Modes until WP-17's `LiveEngineReadinessSource` (ADR-0012 D1).
@MainActor
struct ModesInterimReadiness: EngineReadinessSource {
    func readiness(of engine: EngineID) -> EngineReadiness {
        guard let module = ProviderRegistry.shared.module(id: engine.rawValue) else { return .unavailable }
        if module.requiresKey, !ProviderKeyStore.shared.hasKey(for: module.id) { return .needsKey }
        guard case let .download(bytes) = module.traits.obtainedBy,
              module.traits.needs.contains(.appleSilicon) else { return .ready }
        if !ParakeetModelStore.isSupportedHardware { return .unsupportedHardware }
        return ParakeetModelStore.isDownloaded ? .ready : .notDownloaded(bytes: bytes)
    }
}
