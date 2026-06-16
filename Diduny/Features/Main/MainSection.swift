import SwiftUI

enum MainSection: String, Hashable {
    case overview
    case recordings
    case typingTest
    case meetings

    case general
    case audioDictation
    case models
    case shortcuts
    case account

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
        case .account: "person.crop.circle"
        }
    }

    var isSettingsItem: Bool {
        switch self {
        case .general, .audioDictation, .models, .shortcuts, .account: true
        default: false
        }
    }

    var isBetaDisabled: Bool {
        self == .meetings
    }
}
