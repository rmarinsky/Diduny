import SwiftUI

enum MainSection: String, CaseIterable, Hashable {
    case overview
    case recordings
    case notes
    case clipboard
    case benchmark
    case typingTest

    case general
    case modes
    case languages
    case vocabulary
    /// Label "Layout fixes"; the sidebar row reads "Mistyping".
    case typing
    /// Label "Audio"; the raw value stays so `section.audioDictation` is stable.
    case audioDictation
    case meetings
    case models
    case providers
    case account
    case about

    /// Sidebar rows.
    static let mainItems: [MainSection] = [.overview, .recordings, .notes, .clipboard, .vocabulary]
    static let settingsItems: [MainSection] = [.general, .modes, .languages, .typing, .meetings, .models, .account, .about]

    /// The page a sub-page goes back to; the sidebar shows that row selected. Nil for a sidebar row.
    var parent: MainSection? {
        switch self {
        case .typingTest: .typing
        case .audioDictation: .meetings
        case .providers, .benchmark: .models
        default: nil
        }
    }

    /// The sidebar row this page sits under.
    var row: MainSection { parent ?? self }

    /// The sidebar row's label; `label` stays the page and tab label.
    var sidebarLabel: String {
        switch self {
        case .modes: String(localized: "Modes & shortcuts")
        case .typing: String(localized: "Mistyping")
        case .meetings: String(localized: "Calendar")
        case .models: String(localized: "Engines")
        case .about: String(localized: "About Diduny")
        default: label
        }
    }

    var label: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .recordings: String(localized: "Recordings")
        case .notes: String(localized: "Notes")
        case .clipboard: String(localized: "Clipboard")
        case .benchmark: String(localized: "Benchmark")
        case .typingTest: String(localized: "Typing test")
        case .meetings: String(localized: "Calendar & meetings")
        case .general: String(localized: "General")
        case .modes: String(localized: "Modes & shortcuts")
        case .languages: String(localized: "Languages")
        case .vocabulary: String(localized: "Vocabulary")
        case .typing: String(localized: "Layout fixes")
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
        case .clipboard: "doc.on.clipboard"
        case .benchmark: "chart.bar.xaxis"
        case .typingTest: "keyboard"
        case .meetings: "calendar"
        case .general: "gearshape"
        case .modes: "slider.horizontal.3"
        case .languages: "globe"
        case .vocabulary: "text.book.closed"
        case .typing: "keyboard"
        case .audioDictation: "waveform.and.mic"
        case .models: "cpu"
        case .providers: "key.horizontal"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        }
    }
}

/// The "Settings" button in a data page's header: opens the settings page that holds that page's options.
struct SettingsPageButton: View {
    let target: MainSection

    var body: some View {
        Button("Settings") { MainWindowController.shared.showWindow(section: target) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("page.settings.\(target.rawValue)")
    }
}
