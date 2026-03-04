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
        "ммм",
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
        "sort of",
    ]
    private static let defaultFillerWords = normalizedFillerWords(baseFillerWords + englishFillerWordPreset)

    private enum Key: String {
        case selectedDeviceID
        case autoPaste
        case playSoundOnCompletion
        case launchAtLogin
        case pushToTalkKey
        case meetingAudioSource
        case meetingMicGain
        case meetingSystemGain
        case translationPushToTalkKey
        case handsFreeModeEnabled
        case transcriptionProvider
        case selectedWhisperModel
        case whisperLanguage
        case whisperPrompt
        case favoriteLanguages
        case hasCloudAPIKey
        case translationRealtimeSocketEnabled
        case transcriptionRealtimeSocketEnabled
        case meetingRealtimeTranscriptionEnabled
        case escapeCancelEnabled
        case escapeCancelShortcut
        case escapeCancelSaveAudio
        case textCleanupEnabled
        case fillerWords
        case pauseParagraphThresholdMs
        case sonioxEndpointDelayMs
    }

    private init() {}

    // MARK: - Audio Device

    var selectedDeviceID: AudioDeviceID? {
        get {
            let value = defaults.integer(forKey: Key.selectedDeviceID.rawValue)
            return value > 0 ? AudioDeviceID(value) : nil
        }
        set {
            if let id = newValue {
                defaults.set(Int(id), forKey: Key.selectedDeviceID.rawValue)
            } else {
                defaults.removeObject(forKey: Key.selectedDeviceID.rawValue)
            }
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
                // Default to Right Shift for double-tap mode
                return .rightShift
            }
            return key
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.pushToTalkKey.rawValue)
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

    // MARK: - Hands-Free Mode (Double-Tap Toggle)

    /// When enabled, double-tap starts/stops recording (toggle mode)
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

    // MARK: - Transcription Provider

    var transcriptionProvider: TranscriptionProvider {
        get {
            guard let rawValue = defaults.string(forKey: Key.transcriptionProvider.rawValue),
                  let provider = TranscriptionProvider(rawValue: rawValue)
            else {
                return .whisperLocal
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.transcriptionProvider.rawValue)
        }
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

    // MARK: - Translation Realtime Socket

    /// Enables cloud realtime translation over Soniox websocket during translation recording.
    var translationRealtimeSocketEnabled: Bool {
        get {
            if defaults.object(forKey: Key.translationRealtimeSocketEnabled.rawValue) == nil {
                return true
            }
            return defaults.bool(forKey: Key.translationRealtimeSocketEnabled.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.translationRealtimeSocketEnabled.rawValue) }
    }

    // MARK: - Transcription Realtime Socket

    /// Enables cloud realtime transcription over Soniox websocket during voice dictation.
    /// Disabled by default to keep existing async cloud behavior unless explicitly enabled.
    var transcriptionRealtimeSocketEnabled: Bool {
        get { defaults.bool(forKey: Key.transcriptionRealtimeSocketEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.transcriptionRealtimeSocketEnabled.rawValue) }
    }

    // MARK: - Pause Paragraph Segmentation

    /// Pause duration (ms) that triggers a new paragraph/line in transcription formatting.
    /// Applied to realtime socket mode and async Soniox token formatting.
    var pauseParagraphThresholdMs: Int {
        get {
            if defaults.object(forKey: Key.pauseParagraphThresholdMs.rawValue) == nil {
                return 1200
            }
            return Self.sanitizedPauseThresholdMs(defaults.integer(forKey: Key.pauseParagraphThresholdMs.rawValue))
        }
        set {
            defaults.set(
                Self.sanitizedPauseThresholdMs(newValue),
                forKey: Key.pauseParagraphThresholdMs.rawValue
            )
        }
    }

    // MARK: - Meeting Cloud Mode

    /// `true` = Cloud mode (realtime websocket + async fallback when API key exists).
    /// `false` = Local mode (audio recording only, process later from Recordings).
    /// If API key is missing, recording still works as audio-only in both modes.
    var meetingRealtimeTranscriptionEnabled: Bool {
        get { defaults.bool(forKey: Key.meetingRealtimeTranscriptionEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.meetingRealtimeTranscriptionEnabled.rawValue) }
    }

    // MARK: - Escape Cancel

    /// Enables double-press Escape cancellation during active recording.
    var escapeCancelEnabled: Bool {
        get {
            if defaults.object(forKey: Key.escapeCancelEnabled.rawValue) == nil {
                return true
            }
            return defaults.bool(forKey: Key.escapeCancelEnabled.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.escapeCancelEnabled.rawValue) }
    }

    /// Shortcut used for double-press cancellation during active recording.
    /// Default is Escape (double-press).
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

    // MARK: - Cloud API Key Flag

    var hasCloudAPIKey: Bool {
        get { defaults.bool(forKey: Key.hasCloudAPIKey.rawValue) }
        set { defaults.set(newValue, forKey: Key.hasCloudAPIKey.rawValue) }
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

    // MARK: - Soniox Endpoint Delay

    /// Delay (ms) that Soniox uses to detect speech endpoints and place periods.
    /// Higher values = fewer periods from Soniox. Range: 500–5000ms.
    var sonioxEndpointDelayMs: Int {
        get {
            if defaults.object(forKey: Key.sonioxEndpointDelayMs.rawValue) == nil {
                return 1200
            }
            return Self.sanitizedEndpointDelayMs(defaults.integer(forKey: Key.sonioxEndpointDelayMs.rawValue))
        }
        set {
            defaults.set(
                Self.sanitizedEndpointDelayMs(newValue),
                forKey: Key.sonioxEndpointDelayMs.rawValue
            )
        }
    }

    private static func sanitizedPauseThresholdMs(_ value: Int) -> Int {
        min(max(value, 250), 3000)
    }

    private static func sanitizedEndpointDelayMs(_ value: Int) -> Int {
        min(max(value, 500), 5000)
    }
}

extension Notification.Name {
    static let textCleanupSettingsChanged = Notification.Name("textCleanupSettingsChanged")
}
