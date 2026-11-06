import Foundation

/// Mode defaults and per-mode values (ADR-0012 D4, plan 3.2).
extension SettingsStorage {
    private enum ModeDefaultsKey: String {
        case dictationTranslationTargetLanguage
        case meetingTranslationShowOriginal
        case translationSilenceAutoStopEnabled
        case translationSilenceAutoStopSeconds
        case meetingTranslationSilenceAutoStopEnabled
        case meetingTranslationSilenceAutoStopSeconds
    }

    var modeDefaults: ModeDefaults { ModeDefaults(defaults: defaults) }

    /// Translation "Into"; nil = follow `defaultTranslationTargetLanguage`.
    var dictationTranslationTargetLanguage: String? {
        get { defaults.string(forKey: ModeDefaultsKey.dictationTranslationTargetLanguage.rawValue) }
        set { defaults.set(newValue, forKey: ModeDefaultsKey.dictationTranslationTargetLanguage.rawValue) }
    }

    var effectiveDictationTranslationTargetLanguage: String {
        dictationTranslationTargetLanguage ?? defaultTranslationTargetLanguage
    }

    var meetingTranslationShowOriginal: Bool {
        get { defaults.bool(forKey: ModeDefaultsKey.meetingTranslationShowOriginal.rawValue) }
        set { defaults.set(newValue, forKey: ModeDefaultsKey.meetingTranslationShowOriginal.rawValue) }
    }

    // MARK: Stop after silence, split per mode (05 Q5). Unset reads the shared value, as today.

    var translationSilenceAutoStopEnabled: Bool {
        get { bool(.translationSilenceAutoStopEnabled) ?? dictationSilenceAutoStopEnabled }
        set { defaults.set(newValue, forKey: ModeDefaultsKey.translationSilenceAutoStopEnabled.rawValue) }
    }

    var translationSilenceAutoStopSeconds: Double {
        get { clamped(.translationSilenceAutoStopSeconds, Self.dictationSilenceAutoStopRange) ?? dictationSilenceAutoStopSeconds }
        set { set(newValue, .translationSilenceAutoStopSeconds, Self.dictationSilenceAutoStopRange) }
    }

    var meetingTranslationSilenceAutoStopEnabled: Bool {
        get { bool(.meetingTranslationSilenceAutoStopEnabled) ?? meetingSilenceAutoStopEnabled }
        set { defaults.set(newValue, forKey: ModeDefaultsKey.meetingTranslationSilenceAutoStopEnabled.rawValue) }
    }

    var meetingTranslationSilenceAutoStopSeconds: Double {
        get { clamped(.meetingTranslationSilenceAutoStopSeconds, Self.meetingSilenceAutoStopRange) ?? meetingSilenceAutoStopSeconds }
        set { set(newValue, .meetingTranslationSilenceAutoStopSeconds, Self.meetingSilenceAutoStopRange) }
    }

    /// "Stop after silence" of a mode; Files has none and reads Dictation's.
    func silenceAutoStop(for job: STTJob) -> ModeSilence {
        switch job {
        case .dictation, .file: ModeSilence(enabled: dictationSilenceAutoStopEnabled, seconds: dictationSilenceAutoStopSeconds)
        case .dictationTranslation: ModeSilence(enabled: translationSilenceAutoStopEnabled, seconds: translationSilenceAutoStopSeconds)
        case .meeting: ModeSilence(enabled: meetingSilenceAutoStopEnabled, seconds: meetingSilenceAutoStopSeconds)
        case .meetingTranslation:
            ModeSilence(enabled: meetingTranslationSilenceAutoStopEnabled, seconds: meetingTranslationSilenceAutoStopSeconds)
        }
    }

    private func bool(_ key: ModeDefaultsKey) -> Bool? {
        defaults.object(forKey: key.rawValue) == nil ? nil : defaults.bool(forKey: key.rawValue)
    }

    private func clamped(_ key: ModeDefaultsKey, _ range: ClosedRange<Double>) -> Double? {
        (defaults.object(forKey: key.rawValue) as? Double).map { min(max($0, range.lowerBound), range.upperBound) }
    }

    private func set(_ value: Double, _ key: ModeDefaultsKey, _ range: ClosedRange<Double>) {
        defaults.set(min(max(value, range.lowerBound), range.upperBound), forKey: key.rawValue)
    }
}
