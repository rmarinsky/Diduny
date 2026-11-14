import SwiftUI

enum MainSection: String, CaseIterable, Hashable {
    case overview
    case recordings
    case notes
    case benchmark
    case typingTest

    case general
    case modes
    case languages
    case vocabulary
    /// Label "Audio"; the raw value stays so `section.audioDictation` is stable.
    case audioDictation
    case meetings
    case notesSettings
    case models
    case providers
    case account
    case about

    /// Sidebar rows. A row is named by its first page; `tabs` lists the pages it holds.
    static let mainItems: [MainSection] = [.overview, .recordings, .notes, .typingTest]
    static let settingsItems: [MainSection] = [.general, .modes, .vocabulary, .meetings, .models, .account, .about]

    /// The pages that share this page's sidebar row, in tab order. One page: no switch.
    var tabs: [MainSection] {
        switch self {
        case .modes, .languages, .audioDictation: [.modes, .languages, .audioDictation]
        case .meetings, .notesSettings: [.meetings, .notesSettings]
        case .models, .providers, .benchmark: [.models, .providers, .benchmark]
        default: [self]
        }
    }

    /// The sidebar row's label; `label` stays the page and tab label.
    var sidebarLabel: String {
        switch self {
        case .modes: String(localized: "Dictation")
        case .meetings: String(localized: "Meetings & notes")
        case .models: String(localized: "Models")
        default: label
        }
    }

    var label: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .recordings: String(localized: "Recordings")
        case .notes: String(localized: "Notes")
        case .benchmark: String(localized: "Benchmark")
        case .typingTest: String(localized: "Typing test")
        case .meetings: String(localized: "Calendar & meetings")
        case .notesSettings: String(localized: "Notes settings")
        case .general: String(localized: "General")
        case .modes: String(localized: "Modes & shortcuts")
        case .languages: String(localized: "Languages")
        case .vocabulary: String(localized: "Vocabulary & context")
        case .audioDictation: String(localized: "Audio")
        case .models: String(localized: "Local models")
        case .providers: String(localized: "Providers")
        case .account: String(localized: "Account")
        case .about: String(localized: "About")
        }
    }

    var iconName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .recordings: "waveform"
        case .notes: "doc.text"
        case .benchmark: "chart.bar.xaxis"
        case .typingTest: "keyboard"
        case .meetings: "calendar"
        case .notesSettings: "doc.text.magnifyingglass"
        case .general: "gearshape"
        case .modes: "slider.horizontal.3"
        case .languages: "globe"
        case .vocabulary: "text.book.closed"
        case .audioDictation: "waveform.and.mic"
        case .models: "cpu"
        case .providers: "key.horizontal"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        }
    }
}
