import KeyboardShortcuts
import Testing
@testable import Diduny

/// T5-SB-01 and T5-HK-41 (panels redesign WP-50).
/// Main actor: a shortcut's text reads the keyboard layout (Text Input Sources), which traps off the
/// main thread on the macOS 26 runner. The app builds it in the SwiftUI body, on the main actor.
@MainActor
struct MainSectionSidebarTests {
    @Test func mainItemsInOrder() {
        #expect(MainSection.mainItems == [.overview, .recordings, .notes])
    }

    @Test func settingsItemsInOrder() {
        #expect(MainSection.settingsItems == [.general, .modes, .vocabulary, .typing, .meetings, .models, .account, .about])
    }

    @Test func sidebarLabels() {
        let labels = (MainSection.mainItems + MainSection.settingsItems).map(\.sidebarLabel)
        #expect(labels == [
            "Overview", "Recordings", "Notes",
            "General", "Dictation", "Vocabulary & context", "Typing", "Meetings & notes", "Models", "Account", "About",
        ])
    }

    @Test func tabsOfEachRowInOrder() {
        #expect(MainSection.modes.tabs.map(\.label) == ["Modes & shortcuts", "Languages", "Audio"])
        #expect(MainSection.typing.tabs.map(\.label) == ["Layout fixes", "Typing test"])
        #expect(MainSection.meetings.tabs.map(\.label) == ["Calendar & meetings", "Notes settings"])
        #expect(MainSection.models.tabs.map(\.label) == ["Local models", "Providers", "Benchmark"])
        let single: [MainSection] = [.overview, .recordings, .notes, .general, .vocabulary, .account, .about]
        for row in single {
            #expect(row.tabs == [row])
        }
    }

    /// Every page sits under exactly one sidebar row, and the pages of a row share one tab list.
    @Test func everyPageBelongsToOneRow() {
        let rows = MainSection.mainItems + MainSection.settingsItems
        #expect(Set(rows).count == rows.count)
        #expect(Set(rows.flatMap(\.tabs)) == Set(MainSection.allCases))
        #expect(rows.flatMap(\.tabs).count == MainSection.allCases.count)
        for page in MainSection.allCases {
            #expect(page.tabs.contains(page))
            #expect(rows.filter { $0 == page.tabs.first }.count == 1)
            #expect(page.tabs.first?.tabs == page.tabs)
        }
    }

    /// The sidebar fills the row `tabs.first`; the switch shows `tabs` with the page itself selected.
    @Test func openingAPageSelectsItsRowAndTab() {
        let expected: [MainSection: MainSection] = [
            .overview: .overview, .recordings: .recordings, .notes: .notes,
            .general: .general, .modes: .modes, .languages: .modes, .audioDictation: .modes, .vocabulary: .vocabulary,
            .typing: .typing, .typingTest: .typing,
            .meetings: .meetings, .notesSettings: .meetings,
            .models: .models, .providers: .models, .benchmark: .models,
            .account: .account, .about: .about,
        ]
        #expect(expected.count == MainSection.allCases.count)
        for (page, row) in expected {
            #expect(page.tabs.first == row)
        }
    }

    /// A sidebar click selects the row, which is its own first tab.
    @Test func aRowOpensOnItsFirstTab() {
        for row in MainSection.mainItems + MainSection.settingsItems {
            #expect(row.tabs.first == row)
        }
    }

    @Test func pageLabelsStay() {
        #expect(MainSection.modes.label == "Modes & shortcuts")
        #expect(MainSection.meetings.label == "Calendar & meetings")
        #expect(MainSection.models.label == "Local models")
        #expect(MainSection.typingTest.label == "Typing test")
    }

    @Test func newItemIcons() {
        #expect(MainSection.modes.iconName == "slider.horizontal.3")
        #expect(MainSection.languages.iconName == "globe")
        #expect(MainSection.audioDictation.iconName == "waveform.and.mic")
        #expect(MainSection.typing.iconName == "keyboard")
    }

    @Test func audioKeepsItsRawValue() {
        #expect(MainSection.audioDictation.rawValue == "audioDictation")
    }

    /// `section.typingTest` and `--ui-testing-open=settings.typing` depend on these.
    @Test func typingRawValues() {
        #expect(MainSection.typing.rawValue == "typing")
        #expect(MainSection.typingTest.rawValue == "typingTest")
    }

    @Test func footerShortcutDefault() {
        #expect(SidebarView.footerShortcutText(KeyboardShortcuts.Name.toggleRecording.defaultShortcut) == "⌥⌘D")
    }

    @Test func footerShortcutChanged() {
        #expect(SidebarView.footerShortcutText(.init(.k, modifiers: [.command, .option])) == "⌥⌘K")
    }

    @Test func footerShortcutRemoved() {
        #expect(SidebarView.footerShortcutText(nil) == nil)
    }
}
