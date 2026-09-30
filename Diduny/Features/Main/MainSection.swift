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
    case speech
    case account

    static let mainItems = allCases.filter { !$0.isSettingsItem }
    static let settingsItems = allCases.filter(\.isSettingsItem)

    var label: String {
        switch self {
        case .overview: "Overview"
        case .recordings: "Recordings"
        case .typingTest: "Typing Test"
        case .meetings: "Meetings"
        case .general: "General"
        case .audioDictation: "Audio & Dictation"
        case .models: "Models"
        case .shortcuts: "Shortcuts"
        case .speech: "Speech"
        case .account: "Account"
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
        case .speech: "speaker.wave.2"
        case .account: "person.crop.circle"
        }
    }

    var isSettingsItem: Bool {
        switch self {
        case .meetings, .general, .audioDictation, .models, .shortcuts, .speech, .account: true
        default: false
        }
    }
}
