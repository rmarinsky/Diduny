import CoreAudio
import Foundation

final class SettingsStorage {
    static let shared = SettingsStorage()

    private let defaults = UserDefaults.standard

    private enum Key: String {
        case useAutoDetect
        case selectedDeviceID
        case audioQuality
        case autoPaste
        case playSoundOnCompletion
        case launchAtLogin
        case pushToTalkKey
        case meetingAudioSource
        case translationPushToTalkKey
    }

    private init() {}

    // MARK: - Audio Device

    var useAutoDetect: Bool {
        get { defaults.bool(forKey: Key.useAutoDetect.rawValue) }
        set { defaults.set(newValue, forKey: Key.useAutoDetect.rawValue) }
    }

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

    // MARK: - Audio Quality

    var audioQuality: AudioQuality {
        get {
            guard let rawValue = defaults.string(forKey: Key.audioQuality.rawValue),
                  let quality = AudioQuality(rawValue: rawValue)
            else {
                return .medium
            }
            return quality
        }
        set { defaults.set(newValue.rawValue, forKey: Key.audioQuality.rawValue) }
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
        get { defaults.bool(forKey: Key.launchAtLogin.rawValue) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin.rawValue) }
    }

    // MARK: - Push to Talk

    var pushToTalkKey: PushToTalkKey {
        get {
            guard let rawValue = defaults.string(forKey: Key.pushToTalkKey.rawValue),
                  let key = PushToTalkKey(rawValue: rawValue)
            else {
                return .rightOption
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
                return .systemOnly
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
}
