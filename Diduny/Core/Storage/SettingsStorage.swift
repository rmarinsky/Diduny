import CoreAudio
import Foundation
import LaunchAtLogin

final class SettingsStorage {
    static let shared = SettingsStorage()

    private let defaults = UserDefaults.standard
    private static let baseFillerWords = [
        "е-е",
        "ем",
        "мм",
        "ммм"
    ]
    private static let englishFillerWordPreset = [
        "uh",
        "uhh",
        "um",
        "umm",
        "em",
        "er",
        "erm",
        "hmm",
        "hm",
        "mmm",
        "mm-hmm",
        "uh-huh",
        "you know",
        "i mean",
        "kind of",
        "sort of"
    ]
    private static let defaultFillerWords = normalizedFillerWords(baseFillerWords + englishFillerWordPreset)

    private enum Key: String {
        case selectedDeviceUID // Legacy — kept for migration only
        case preferredDeviceUID
        case microphoneSelectionStrategy
        case autoPaste
        case playSoundOnCompletion
        case launchAtLogin
        case pushToTalkKey
        case pushToTalkToggleTapCount
        case meetingAudioSource
        case meetingMicGain
        case meetingSystemGain
        case translationPushToTalkKey
        case translationPushToTalkToggleTapCount
        case handsFreeModeEnabled
        case recordingHotkeyPressCount
        case translationHotkeyPressCount
        case meetingHotkeyPressCount
        case meetingTranslationHotkeyPressCount
        case transcriptionProvider
        case selectedWhisperModel
        case whisperLanguage
        case whisperPrompt
        case favoriteLanguages
        case translationLanguageA
        case translationLanguageB
        case translationProvider
        case translationRealtimeSocketEnabled
        case transcriptionRealtimeSocketEnabled
        case meetingRealtimeTranscriptionEnabled
        case escapeCancelEnabled
        case escapeCancelShortcut
        case escapeCancelPressCount
        case escapeCancelSaveAudio
        case textCleanupEnabled
        case fillerWords
        case proxyBaseURL
        case remoteConfigURL
    }

    private init() {
        migrateSelectedDeviceIfNeeded()
        migratePreferredDeviceKeyIfNeeded()
        migrateTranscriptionProviderIfNeeded()
    }

    /// One-time migration from legacy `selectedDeviceID` (AudioDeviceID int) to `selectedDeviceUID` (String).
    private func migrateSelectedDeviceIfNeeded() {
        let legacyKey = "selectedDeviceID"
        let legacyValue = defaults.integer(forKey: legacyKey)
        guard legacyValue > 0,
              defaults.string(forKey: Key.selectedDeviceUID.rawValue) == nil else { return }

        // Resolve UID from AudioDeviceID via CoreAudio
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        let deviceID = AudioDeviceID(legacyValue)
        var cfUID: CFString?
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &cfUID)
        guard status == noErr, let cfUID else { return } // keep legacy key for retry on next launch
        let uid = cfUID as String
        defaults.set(uid, forKey: Key.selectedDeviceUID.rawValue)
        defaults.removeObject(forKey: legacyKey)
    }

    /// One-time migration from `selectedDeviceUID` → `preferredDeviceUID`.
    private func migratePreferredDeviceKeyIfNeeded() {
        guard let oldValue = defaults.string(forKey: Key.selectedDeviceUID.rawValue),
              defaults.string(forKey: Key.preferredDeviceUID.rawValue) == nil else { return }
        defaults.set(oldValue, forKey: Key.preferredDeviceUID.rawValue)
        defaults.removeObject(forKey: Key.selectedDeviceUID.rawValue)
    }

    /// Migrate old provider rawValues: "soniox" → "cloud", "whisper_local" → "local"
    private func migrateTranscriptionProviderIfNeeded() {
        guard let stored = defaults.string(forKey: Key.transcriptionProvider.rawValue) else { return }
        switch stored {
        case "soniox":
            defaults.set(TranscriptionProvider.cloud.rawValue, forKey: Key.transcriptionProvider.rawValue)
        case "whisper_local":
            defaults.set(TranscriptionProvider.local.rawValue, forKey: Key.transcriptionProvider.rawValue)
        default:
            break
        }
    }

    // MARK: - Audio Device

    /// Preferred device UID. `nil` means "follow System Default".
    var preferredDeviceUID: String? {
        get {
            defaults.string(forKey: Key.preferredDeviceUID.rawValue)
        }
        set {
            if let uid = newValue {
                defaults.set(uid, forKey: Key.preferredDeviceUID.rawValue)
            } else {
                defaults.removeObject(forKey: Key.preferredDeviceUID.rawValue)
            }
        }
    }

    var microphoneSelectionStrategy: MicrophoneSelectionStrategy {
        get {
            guard let rawValue = defaults.string(forKey: Key.microphoneSelectionStrategy.rawValue),
                  let strategy = MicrophoneSelectionStrategy(rawValue: rawValue)
            else {
                return .auto
            }
            return strategy
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.microphoneSelectionStrategy.rawValue)
        }
    }

    // MARK: - Behavior

    var autoPaste: Bool {
        get { defaults.object(forKey: Key.autoPaste.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoPaste.rawValue) }
    }

    var playSoundOnCompletion: Bool {
        get { defaults.object(forKey: Key.playSoundOnCompletion.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSoundOnCompletion.rawValue) }
    }

    var launchAtLogin: Bool {
        get { LaunchAtLogin.isEnabled }
        set { LaunchAtLogin.isEnabled = newValue }
    }

    var textCleanupEnabled: Bool {
        get {
            if defaults.object(forKey: Key.textCleanupEnabled.rawValue) == nil {
                return true
            }
            return defaults.bool(forKey: Key.textCleanupEnabled.rawValue)
        }
        set {
            defaults.set(newValue, forKey: Key.textCleanupEnabled.rawValue)
            NotificationCenter.default.post(name: .textCleanupSettingsChanged, object: nil)
        }
    }

    var fillerWords: [String] {
        get {
            guard let stored = defaults.stringArray(forKey: Key.fillerWords.rawValue) else {
                return Self.defaultFillerWords
            }
            return Self.normalizedFillerWords(stored)
        }
        set {
            defaults.set(Self.normalizedFillerWords(newValue), forKey: Key.fillerWords.rawValue)
            NotificationCenter.default.post(name: .textCleanupSettingsChanged, object: nil)
        }
    }

    @discardableResult
    func addFillerWord(_ word: String) -> Bool {
        addFillerWords([word]) > 0
    }

    @discardableResult
    func addFillerWords(_ words: [String]) -> Int {
        let candidates = Self.normalizedFillerWords(words)
        guard !candidates.isEmpty else { return 0 }

        var current = fillerWords
        var currentKeys = Set(current.map { Self.foldedWordKey($0) })
        var addedCount = 0

        for candidate in candidates {
            let candidateKey = Self.foldedWordKey(candidate)
            guard currentKeys.insert(candidateKey).inserted else { continue }
            current.append(candidate)
            addedCount += 1
        }

        guard addedCount > 0 else { return 0 }
        fillerWords = current
        return addedCount
    }

    @discardableResult
    func addEnglishFillerWordPreset() -> Int {
        addFillerWords(Self.englishFillerWordPreset)
    }

    var englishFillerWordPreset: [String] {
        Self.englishFillerWordPreset
    }

    func removeFillerWord(_ word: String) {
        let targetKey = Self.foldedWordKey(word)
        let filtered = fillerWords.filter { Self.foldedWordKey($0) != targetKey }
        guard filtered.count != fillerWords.count else { return }
        fillerWords = filtered
    }

    func resetFillerWordsToDefault() {
        fillerWords = Self.defaultFillerWords
    }

    // MARK: - Push to Talk

    var pushToTalkKey: PushToTalkKey {
        get {
            guard let rawValue = defaults.string(forKey: Key.pushToTalkKey.rawValue),
                  let key = PushToTalkKey(rawValue: rawValue)
            else {
                // Default to Right Shift for modifier-key shortcut mode
                return .rightShift
            }
            return key
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.pushToTalkKey.rawValue)
        }
    }

    /// Number of presses required to toggle dictation via the selected modifier key in hands-free mode.
    var pushToTalkToggleTapCount: Int {
        get {
            let stored = defaults.object(forKey: Key.pushToTalkToggleTapCount.rawValue) as? Int ?? 3
            return Self.sanitizedTapCount(stored, fallback: 3)
        }
        set {
            defaults.set(
                Self.sanitizedTapCount(newValue, fallback: 3),
                forKey: Key.pushToTalkToggleTapCount.rawValue
            )
        }
    }

    // MARK: - Meeting Recording

    var meetingAudioSource: MeetingAudioSource {
        get {
            guard let rawValue = defaults.string(forKey: Key.meetingAudioSource.rawValue),
                  let source = MeetingAudioSource(rawValue: rawValue)
            else {
                return .systemPlusMicrophone
            }
            return source
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.meetingAudioSource.rawValue)
        }
    }

    // MARK: - Meeting Gain Controls

    var meetingMicGain: Float {
        get {
            let stored = defaults.object(forKey: Key.meetingMicGain.rawValue) as? Float ?? 1.0
            return Self.sanitizedGain(stored, fallback: 1.0)
        }
        set { defaults.set(Self.sanitizedGain(newValue, fallback: 1.0), forKey: Key.meetingMicGain.rawValue) }
    }

    var meetingSystemGain: Float {
        get {
            let stored = defaults.object(forKey: Key.meetingSystemGain.rawValue) as? Float ?? 0.3
            return Self.sanitizedGain(stored, fallback: 0.3)
        }
        set { defaults.set(Self.sanitizedGain(newValue, fallback: 0.3), forKey: Key.meetingSystemGain.rawValue) }
    }

    // MARK: - Translation Push to Talk

    var translationPushToTalkKey: PushToTalkKey {
        get {
            guard let rawValue = defaults.string(forKey: Key.translationPushToTalkKey.rawValue),
                  let key = PushToTalkKey(rawValue: rawValue)
            else {
                return .none
            }
            return key
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.translationPushToTalkKey.rawValue)
        }
    }

    /// Number of presses required to toggle translation via the selected modifier key in hands-free mode.
    var translationPushToTalkToggleTapCount: Int {
        get {
            let stored = defaults.object(forKey: Key.translationPushToTalkToggleTapCount.rawValue) as? Int ?? 3
            return Self.sanitizedTapCount(stored, fallback: 3)
        }
        set {
            defaults.set(
                Self.sanitizedTapCount(newValue, fallback: 3),
                forKey: Key.translationPushToTalkToggleTapCount.rawValue
            )
        }
    }

    // MARK: - Hands-Free Mode (Multi-Tap Toggle)

    /// When enabled, multi-tap starts/stops recording (toggle mode)
    /// When disabled, hold-to-record mode is used
    var handsFreeModeEnabled: Bool {
        get {
            // Default to false (push-to-talk hold mode)
            // Use object check to distinguish "not set" from "set to false"
            if defaults.object(forKey: Key.handsFreeModeEnabled.rawValue) == nil {
                return false
            }
            return defaults.bool(forKey: Key.handsFreeModeEnabled.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.handsFreeModeEnabled.rawValue) }
    }

    // MARK: - Global Hotkey Press Counts

    var recordingHotkeyPressCount: Int {
        get {
            let stored = defaults.object(forKey: Key.recordingHotkeyPressCount.rawValue) as? Int ?? 1
            return Self.sanitizedPressCount(stored, fallback: 1)
        }
        set {
            defaults.set(
                Self.sanitizedPressCount(newValue, fallback: 1),
                forKey: Key.recordingHotkeyPressCount.rawValue
            )
        }
    }

    var translationHotkeyPressCount: Int {
        get {
            let stored = defaults.object(forKey: Key.translationHotkeyPressCount.rawValue) as? Int ?? 1
            return Self.sanitizedPressCount(stored, fallback: 1)
        }
        set {
            defaults.set(
                Self.sanitizedPressCount(newValue, fallback: 1),
                forKey: Key.translationHotkeyPressCount.rawValue
            )
        }
    }

    var meetingHotkeyPressCount: Int {
        get {
            let stored = defaults.object(forKey: Key.meetingHotkeyPressCount.rawValue) as? Int ?? 1
            return Self.sanitizedPressCount(stored, fallback: 1)
        }
        set {
            defaults.set(
                Self.sanitizedPressCount(newValue, fallback: 1),
                forKey: Key.meetingHotkeyPressCount.rawValue
            )
        }
    }

    var meetingTranslationHotkeyPressCount: Int {
        get {
            let stored = defaults.object(forKey: Key.meetingTranslationHotkeyPressCount.rawValue) as? Int ?? 1
            return Self.sanitizedPressCount(stored, fallback: 1)
        }
        set {
            defaults.set(
                Self.sanitizedPressCount(newValue, fallback: 1),
                forKey: Key.meetingTranslationHotkeyPressCount.rawValue
            )
        }
    }

    // MARK: - Transcription Provider

    var transcriptionProvider: TranscriptionProvider {
        get {
            guard let rawValue = defaults.string(forKey: Key.transcriptionProvider.rawValue),
                  let provider = TranscriptionProvider(rawValue: rawValue)
            else {
                return .local
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.transcriptionProvider.rawValue)
        }
    }

    var effectiveTranscriptionProvider: TranscriptionProvider {
        transcriptionProvider == .cloud && !AuthService.hasStoredSession ? .local : transcriptionProvider
    }

    var selectedWhisperModel: String {
        get { defaults.string(forKey: Key.selectedWhisperModel.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.selectedWhisperModel.rawValue) }
    }

    // MARK: - Whisper Local Settings

    var whisperLanguage: String {
        get { defaults.string(forKey: Key.whisperLanguage.rawValue) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.whisperLanguage.rawValue) }
    }

    var whisperPrompt: String {
        get { defaults.string(forKey: Key.whisperPrompt.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.whisperPrompt.rawValue) }
    }

    // MARK: - Translation Provider

    var translationProvider: TranscriptionProvider {
        get {
            guard let rawValue = defaults.string(forKey: Key.translationProvider.rawValue),
                  let provider = TranscriptionProvider(rawValue: rawValue)
            else {
                return .cloud
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.translationProvider.rawValue)
        }
    }

    var effectiveTranslationProvider: TranscriptionProvider {
        translationProvider == .cloud && !AuthService.hasStoredSession ? .local : translationProvider
    }

    // MARK: - Translation Realtime Socket

    /// Enables cloud realtime translation over websocket during translation recording.
    var translationRealtimeSocketEnabled: Bool {
        get {
            if defaults.object(forKey: Key.translationRealtimeSocketEnabled.rawValue) == nil {
                return false
            }
            return defaults.bool(forKey: Key.translationRealtimeSocketEnabled.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.translationRealtimeSocketEnabled.rawValue) }
    }

    // MARK: - Transcription Realtime Socket

    /// Enables cloud realtime transcription over websocket during voice dictation.
    /// Disabled by default to keep existing async cloud behavior unless explicitly enabled.
    var transcriptionRealtimeSocketEnabled: Bool {
        get { defaults.bool(forKey: Key.transcriptionRealtimeSocketEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.transcriptionRealtimeSocketEnabled.rawValue) }
    }

    // MARK: - Meeting Cloud Mode

    /// `true` = Cloud mode (realtime websocket + async fallback).
    /// `false` = Local mode (audio recording only, process later from Recordings).
    var meetingRealtimeTranscriptionEnabled: Bool {
        get { defaults.bool(forKey: Key.meetingRealtimeTranscriptionEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.meetingRealtimeTranscriptionEnabled.rawValue) }
    }

    var effectiveMeetingRealtimeTranscriptionEnabled: Bool {
        meetingRealtimeTranscriptionEnabled && AuthService.hasStoredSession
    }

    // MARK: - Escape Cancel

    /// Enables Escape-based cancellation during active recording.
    var escapeCancelEnabled: Bool {
        get {
            if defaults.object(forKey: Key.escapeCancelEnabled.rawValue) == nil {
                return true
            }
            return defaults.bool(forKey: Key.escapeCancelEnabled.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.escapeCancelEnabled.rawValue) }
    }

    /// Legacy custom cancel shortcut storage.
    /// Current UI uses None/Esc only, but we keep the persisted model for compatibility.
    var escapeCancelShortcut: RecordingCancelShortcut {
        get {
            guard let data = defaults.data(forKey: Key.escapeCancelShortcut.rawValue),
                  let shortcut = try? JSONDecoder().decode(RecordingCancelShortcut.self, from: data)
            else {
                return .defaultShortcut
            }
            return shortcut
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.escapeCancelShortcut.rawValue)
        }
    }

    /// Number of Escape presses required to cancel an active recording.
    var escapeCancelPressCount: Int {
        get {
            let stored = defaults.object(forKey: Key.escapeCancelPressCount.rawValue) as? Int ?? 2
            return Self.sanitizedTapCount(stored, fallback: 2)
        }
        set {
            defaults.set(
                Self.sanitizedTapCount(newValue, fallback: 2),
                forKey: Key.escapeCancelPressCount.rawValue
            )
        }
    }

    func escapeCancelRepeatHint(afterPressCount pressCount: Int) -> String {
        let remaining = max(escapeCancelPressCount - pressCount, 0)
        if remaining <= 1 {
            return "Press Esc 1 more time to cancel"
        }
        return "Press Esc \(remaining) more times to cancel"
    }

    /// When enabled, cancelled recordings are still saved to the recordings library.
    var escapeCancelSaveAudio: Bool {
        get {
            if defaults.object(forKey: Key.escapeCancelSaveAudio.rawValue) == nil {
                return true
            }
            return defaults.bool(forKey: Key.escapeCancelSaveAudio.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.escapeCancelSaveAudio.rawValue) }
    }

    // MARK: - Favorite Languages

    var favoriteLanguages: [String] {
        get { defaults.stringArray(forKey: Key.favoriteLanguages.rawValue) ?? ["en", "uk"] }
        set { defaults.set(newValue, forKey: Key.favoriteLanguages.rawValue) }
    }

    // MARK: - Translation Language Pair

    var translationLanguageA: String {
        get { defaults.string(forKey: Key.translationLanguageA.rawValue) ?? "en" }
        set { defaults.set(newValue, forKey: Key.translationLanguageA.rawValue) }
    }

    var translationLanguageB: String {
        get { defaults.string(forKey: Key.translationLanguageB.rawValue) ?? "uk" }
        set { defaults.set(newValue, forKey: Key.translationLanguageB.rawValue) }
    }

    private static func normalizedFillerWords(_ words: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for rawWord in words {
            let trimmed = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = foldedWordKey(trimmed)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }

        return result
    }

    private static func foldedWordKey(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func sanitizedGain(_ value: Float, fallback: Float) -> Float {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 2.0)
    }

    private static func sanitizedPressCount(_ value: Int, fallback: Int) -> Int {
        guard value != 0 else { return fallback }
        return min(max(value, 1), 3)
    }

    private static func sanitizedTapCount(_ value: Int, fallback: Int) -> Int {
        guard value != 0 else { return fallback }
        return min(max(value, 2), 3)
    }

    // MARK: - Proxy Settings

    #if DEV_BUILD
        private static let defaultProxyBaseURL = "http://localhost:3000"
    #else
        private static let defaultProxyBaseURL = "https://diduny-ears-proxy.fly.dev"
    #endif

    var proxyBaseURL: String {
        get { defaults.string(forKey: Key.proxyBaseURL.rawValue) ?? Self.defaultProxyBaseURL }
        set { defaults.set(newValue, forKey: Key.proxyBaseURL.rawValue) }
    }

    var remoteConfigURL: String? {
        get { defaults.string(forKey: Key.remoteConfigURL.rawValue) }
        set {
            if let url = newValue {
                defaults.set(url, forKey: Key.remoteConfigURL.rawValue)
            } else {
                defaults.removeObject(forKey: Key.remoteConfigURL.rawValue)
            }
        }
    }
}

extension Notification.Name {
    static let textCleanupSettingsChanged = Notification.Name("textCleanupSettingsChanged")
}
