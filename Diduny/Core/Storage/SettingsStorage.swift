import CoreAudio
import Foundation
import LaunchAtLogin

final class SettingsStorage {
    static let shared = SettingsStorage()

    private let defaults = UserDefaults.standard

    private enum Key: String {
        case selectedDeviceID
        case autoPaste
        case playSoundOnCompletion
        case launchAtLogin
        case pushToTalkKey
        case meetingAudioSource
        case translationPushToTalkKey
        case handsFreeModeEnabled
        case transcriptionProvider
        case selectedWhisperModel
        case ambientListeningEnabled
        case wakeWord
        case whisperLanguage
        case whisperPrompt
        case sonioxPrompt
        case favoriteLanguages
        case hasCloudAPIKey
        case sonioxLanguageHints
        case sonioxLanguageHintsStrict
        case translationRealtimeSocketEnabled
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

    // MARK: - Soniox Prompt

    var sonioxPrompt: String {
        get { defaults.string(forKey: Key.sonioxPrompt.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.sonioxPrompt.rawValue) }
    }

    // MARK: - Soniox Language Hints

    /// Optional allowed language list sent to Soniox cloud APIs.
    /// Empty means "let Soniox auto-detect all languages".
    var sonioxLanguageHints: [String] {
        get { defaults.stringArray(forKey: Key.sonioxLanguageHints.rawValue) ?? [] }
        set { defaults.set(newValue, forKey: Key.sonioxLanguageHints.rawValue) }
    }

    /// When enabled, Soniox will only consider languages from `sonioxLanguageHints`.
    var sonioxLanguageHintsStrict: Bool {
        get { defaults.bool(forKey: Key.sonioxLanguageHintsStrict.rawValue) }
        set { defaults.set(newValue, forKey: Key.sonioxLanguageHintsStrict.rawValue) }
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

    // MARK: - Ambient Listening

    var ambientListeningEnabled: Bool {
        get { defaults.object(forKey: Key.ambientListeningEnabled.rawValue) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.ambientListeningEnabled.rawValue) }
    }

    var wakeWord: String {
        get { defaults.string(forKey: Key.wakeWord.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.wakeWord.rawValue) }
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
}
