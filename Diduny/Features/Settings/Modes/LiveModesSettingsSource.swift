import Foundation

/// `ModesSettingsSource` over `ModeDefaults` (ADR-0012 D4) and the per-mode keys of `SettingsStorage`.
/// Writes only the new keys; the run time reads them (WP-17), the legacy Cloud/Local keys are not written.
@MainActor
final class LiveModesSettingsSource: ModesSettingsSource {
    private let storage: SettingsStorage
    private let notifications: NotificationCenter

    init(storage: SettingsStorage = .shared, notifications: NotificationCenter = .default) {
        self.storage = storage
        self.notifications = notifications
    }

    private var modes: ModeDefaults { storage.modeDefaults }

    // MARK: Engines

    func engine(for job: STTJob) -> EngineID {
        let engine = modes.engine(for: job)
        // Files run on this Mac only (decision 4): a stored cloud engine runs Whisper (F2).
        guard job == .file, engine == .didunyCloud || engine == .elevenLabs else { return engine }
        return .whisper
    }

    func setEngine(_ engine: EngineID, for job: STTJob) {
        guard job != .meeting else { return setMeetingEngine(engine, for: meetingStartsIn) }
        modes.apply([.engine(job, ModeEngineRules.selection(engine: engine, job: job))])
    }

    var meetingStartsIn: MeetingSegment {
        get { modes.meetingStartsIn }
        set { modes.apply([.startsIn(newValue)]) }
    }

    func meetingEngine(for segment: MeetingSegment) -> EngineID {
        modes.engine(for: segment)
    }

    func setMeetingEngine(_ engine: EngineID, for segment: MeetingSegment) {
        modes.apply([.segmentEngine(segment, ModeEngineRules.selection(engine: engine, job: .meeting, segment: segment))])
    }

    // MARK: Languages

    var dictationTranslationTarget: String {
        get { storage.effectiveDictationTranslationTargetLanguage }
        set { storage.dictationTranslationTargetLanguage = newValue }
    }

    var yourLanguages: [String] { storage.yourLanguages }
    var translationPair: TranslationLanguagePair? { storage.translationPair }
    var offeredTranslationPairs: [TranslationLanguagePair] { storage.offeredTranslationPairs }
    func selectTranslationPair(_ pair: TranslationLanguagePair) { storage.selectTranslationPair(pair) }

    // MARK: Options

    var meetingTranslationShowOriginal: Bool {
        get { storage.meetingTranslationShowOriginal }
        set { storage.meetingTranslationShowOriginal = newValue }
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

    /// Four key pairs, one per mode (05 Q5 default; WP-13 migrates them).
    func silence(for job: STTJob) -> ModeSilence {
        storage.silenceAutoStop(for: job)
    }

    func setSilence(_ value: ModeSilence, for job: STTJob) {
        switch job {
        case .dictation, .file:
            storage.dictationSilenceAutoStopEnabled = value.enabled
            storage.dictationSilenceAutoStopSeconds = value.seconds
        case .dictationTranslation:
            storage.translationSilenceAutoStopEnabled = value.enabled
            storage.translationSilenceAutoStopSeconds = value.seconds
        case .meeting:
            storage.meetingSilenceAutoStopEnabled = value.enabled
            storage.meetingSilenceAutoStopSeconds = value.seconds
        case .meetingTranslation:
            storage.meetingTranslationSilenceAutoStopEnabled = value.enabled
            storage.meetingTranslationSilenceAutoStopSeconds = value.seconds
        }
    }
}
