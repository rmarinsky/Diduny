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
            // Default to true (double-tap mode enabled)
            // Use object check to distinguish "not set" from "set to false"
            if defaults.object(forKey: Key.handsFreeModeEnabled.rawValue) == nil {
                return true
            }
            return defaults.bool(forKey: Key.handsFreeModeEnabled.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.handsFreeModeEnabled.rawValue) }
    }
}
