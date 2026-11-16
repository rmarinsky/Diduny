import Foundation

/// The "Read a calendar from a browser" switch. Not stored until the user flips it; until then it is
/// on only for someone who already connected a browser, so existing users keep reading.
enum BrowserCalendarSetting {
    static let key = "calendar.browser.enabled"

    static func resolve(stored: Bool?, hasSavedConnection: Bool) -> Bool {
        stored ?? hasSavedConnection
    }
}

extension SettingsStorage {
    var browserCalendarStored: Bool? {
        defaults.object(forKey: BrowserCalendarSetting.key) as? Bool
    }

    func setBrowserCalendarEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: BrowserCalendarSetting.key)
    }
}
