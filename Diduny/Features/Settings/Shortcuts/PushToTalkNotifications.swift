import Foundation

/// Push-to-talk settings changes the app delegate listens for. Moved unchanged from the old
/// ShortcutsSettingsView.swift; the push-to-talk controls move to Settings > Modes (WP-51).
extension Notification.Name {
    static let pushToTalkKeyChanged = Notification.Name("pushToTalkKeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
    static let pushToTalkTapCountChanged = Notification.Name("pushToTalkTapCountChanged")
    static let translationPushToTalkTapCountChanged = Notification.Name("translationPushToTalkTapCountChanged")
    static let pushToTalkModeChanged = Notification.Name("pushToTalkModeChanged")
    static let translationPushToTalkModeChanged = Notification.Name("translationPushToTalkModeChanged")
    static let pushToTalkHoldStartDelayChanged = Notification.Name("pushToTalkHoldStartDelayChanged")
    static let translationPushToTalkHoldStartDelayChanged =
        Notification.Name("translationPushToTalkHoldStartDelayChanged")
}
