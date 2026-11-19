import Foundation

/// How long the Clipboard page keeps an entry.
enum ClipboardRetention: String, CaseIterable, Identifiable {
    /// The history is off: nothing new is kept. What is already kept stays until it is cleared.
    case never
    case oneHour
    case oneDay
    case twoDays
    case oneWeek
    case oneMonth
    case forever

    var id: String { rawValue }

    /// nil keeps entries with no time limit.
    var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .oneHour: 3600
        case .oneDay: 86400
        case .twoDays: 2 * 86400
        case .oneWeek: 7 * 86400
        case .oneMonth: 30 * 86400
        case .forever: nil
        }
    }

    var displayName: String {
        switch self {
        case .never: String(localized: "Never")
        case .oneHour: String(localized: "1 hour")
        case .oneDay: String(localized: "1 day")
        case .twoDays: String(localized: "2 days")
        case .oneWeek: String(localized: "1 week")
        case .oneMonth: String(localized: "1 month")
        case .forever: String(localized: "Forever")
        }
    }
}

/// The clipboard history. Every key starts with `clipboard.`.
extension SettingsStorage {
    enum ClipboardKey: String, CaseIterable {
        case retention = "clipboard.retention"
        case keepScreenshots = "clipboard.keepScreenshots"
        case keepDidunyPastes = "clipboard.keepDidunyPastes"
        case skipPasswordManagers = "clipboard.skipPasswordManagers"
    }

    var clipboardRetention: ClipboardRetention {
        get {
            defaults.string(forKey: ClipboardKey.retention.rawValue).flatMap(ClipboardRetention.init(rawValue:)) ?? .oneWeek
        }
        set { defaults.set(newValue.rawValue, forKey: ClipboardKey.retention.rawValue) }
    }

    var clipboardKeepScreenshots: Bool {
        get { defaults.object(forKey: ClipboardKey.keepScreenshots.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: ClipboardKey.keepScreenshots.rawValue) }
    }

    /// Dictated and translated text that Diduny delivered.
    var clipboardKeepDidunyPastes: Bool {
        get { defaults.object(forKey: ClipboardKey.keepDidunyPastes.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: ClipboardKey.keepDidunyPastes.rawValue) }
    }

    var clipboardSkipPasswordManagers: Bool {
        get { defaults.object(forKey: ClipboardKey.skipPasswordManagers.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: ClipboardKey.skipPasswordManagers.rawValue) }
    }
}
