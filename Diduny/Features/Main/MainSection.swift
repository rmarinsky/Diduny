import SwiftUI

enum MainSection: String, CaseIterable, Hashable {
    case overview
    case recordings
    case typingTest

    case general
    case audioDictation
    case meetings
    case models
    case shortcuts
    case account

    static let mainItems = allCases.filter { !$0.isSettingsItem }
    static let settingsItems = allCases.filter(\.isSettingsItem)

    var label: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .recordings: String(localized: "Recordings")
        case .typingTest: String(localized: "Typing Test")
        case .meetings: String(localized: "Meetings")
        case .general: String(localized: "General")
        case .audioDictation: String(localized: "Audio & Dictation")
        case .models: String(localized: "Models")
        case .shortcuts: String(localized: "Shortcuts")
        case .account: String(localized: "Account")
        }
    }

    var iconName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .recordings: "waveform"
        case .typingTest: "keyboard"
        case .meetings: "calendar"
        case .general: "gear"
        case .audioDictation: "waveform.and.mic"
        case .models: "cpu"
        case .shortcuts: "keyboard"
        case .account: "person.crop.circle"
        }
    }

    var isSettingsItem: Bool {
        switch self {
        case .meetings, .general, .audioDictation, .models, .shortcuts, .account: true
        default: false
        }
    }
}
