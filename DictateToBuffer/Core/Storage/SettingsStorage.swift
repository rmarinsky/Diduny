import Foundation
import Carbon

final class SettingsStorage {
    static let shared = SettingsStorage()

    private let defaults = UserDefaults.standard

    private enum Key: String {
        case useAutoDetect
        case selectedDeviceID
        case audioQuality
        case autoPaste
        case playSoundOnCompletion
        case showNotification
        case launchAtLogin
        case globalHotkey
        case pushToTalkKey
        case meetingAudioSource
        case meetingHotkey
        case translationHotkey
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
                  let quality = AudioQuality(rawValue: rawValue) else {
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

    var showNotification: Bool {
        get { defaults.object(forKey: Key.showNotification.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showNotification.rawValue) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin.rawValue) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin.rawValue) }
    }

    // MARK: - Global Hotkey

    var globalHotkey: KeyCombo? {
        get {
            guard let data = defaults.data(forKey: Key.globalHotkey.rawValue) else {
                return .default
            }
            return try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        set {
            if let combo = newValue,
               let data = try? JSONEncoder().encode(combo) {
                defaults.set(data, forKey: Key.globalHotkey.rawValue)
            } else {
                defaults.removeObject(forKey: Key.globalHotkey.rawValue)
            }
        }
    }

    // MARK: - Push to Talk

    var pushToTalkKey: PushToTalkKey {
        get {
            guard let rawValue = defaults.string(forKey: Key.pushToTalkKey.rawValue),
                  let key = PushToTalkKey(rawValue: rawValue) else {
                return .none
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
                  let source = MeetingAudioSource(rawValue: rawValue) else {
                return .systemOnly
            }
            return source
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.meetingAudioSource.rawValue)
        }
    }

    var meetingHotkey: KeyCombo? {
        get {
            guard let data = defaults.data(forKey: Key.meetingHotkey.rawValue) else {
                return KeyCombo(keyCode: 46, modifiers: UInt32(cmdKey | shiftKey)) // ⌘⇧M
            }
            return try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        set {
            if let combo = newValue,
               let data = try? JSONEncoder().encode(combo) {
                defaults.set(data, forKey: Key.meetingHotkey.rawValue)
            } else {
                defaults.removeObject(forKey: Key.meetingHotkey.rawValue)
            }
        }
    }

    // MARK: - Translation

    var translationHotkey: KeyCombo? {
        get {
            guard let data = defaults.data(forKey: Key.translationHotkey.rawValue) else {
                return KeyCombo(keyCode: 17, modifiers: UInt32(cmdKey | shiftKey)) // ⌘⇧T
            }
            return try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        set {
            if let combo = newValue,
               let data = try? JSONEncoder().encode(combo) {
                defaults.set(data, forKey: Key.translationHotkey.rawValue)
            } else {
                defaults.removeObject(forKey: Key.translationHotkey.rawValue)
            }
        }
    }

    var translationPushToTalkKey: PushToTalkKey {
        get {
            guard let rawValue = defaults.string(forKey: Key.translationPushToTalkKey.rawValue),
                  let key = PushToTalkKey(rawValue: rawValue) else {
                return .none
            }
            return key
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.translationPushToTalkKey.rawValue)
        }
    }
}

