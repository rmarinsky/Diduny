import KeyboardShortcuts
import Testing
@testable import Diduny

/// T5-SB-01 and T5-HK-41 (panels redesign WP-50).
/// Main actor: a shortcut's text reads the keyboard layout (Text Input Sources), which traps off the
/// main thread on the macOS 26 runner. The app builds it in the SwiftUI body, on the main actor.
@MainActor
struct MainSectionSidebarTests {
    @Test func mainItemsInOrder() {
        #expect(MainSection.mainItems == [.overview, .recordings, .notes, .clipboard, .vocabulary])
    }

    @Test func settingsItemsInOrder() {
        #expect(MainSection.settingsItems == [.general, .modes, .languages, .typing, .meetings, .models, .account, .about])
    }

    @Test func sidebarLabels() {
        let labels = (MainSection.mainItems + MainSection.settingsItems).map(\.sidebarLabel)
        #expect(labels == [
            "Overview", "Recordings", "Notes", "Clipboard", "Vocabulary",
            "General", "Modes & shortcuts", "Languages", "Mistyping", "Meetings", "Engines", "Account", "About Diduny",
        ])
    }

    /// No tab bars: a sub-page has a "‹ <row>" button back to its row's page.
    @Test func subPagesGoBackToTheirRow() {
        #expect(MainSection.typingTest.parent == .typing)
        #expect(MainSection.audioDictation.parent == .meetings)
        #expect(MainSection.providers.parent == .models)
        #expect(MainSection.benchmark.parent == .models)
        for row in MainSection.mainItems + MainSection.settingsItems {
            #expect(row.parent == nil)
        }
    }

    /// Every page sits under exactly one sidebar row, which the sidebar shows selected.
    @Test func everyPageBelongsToOneRow() {
        let rows = MainSection.mainItems + MainSection.settingsItems
        #expect(Set(rows).count == rows.count)
        for page in MainSection.allCases {
            #expect(rows.contains(page.row))
        }
    }

    @Test func pageLabelsStay() {
        #expect(MainSection.modes.label == "Modes & shortcuts")
        #expect(MainSection.meetings.label == "Meetings")
        #expect(MainSection.meetings.sidebarLabel == "Meetings")
        #expect(MainSection.models.label == "Local models")
        #expect(MainSection.typingTest.label == "Typing test")
    }

    @Test func newItemIcons() {
        #expect(MainSection.modes.iconName == "slider.horizontal.3")
        #expect(MainSection.languages.iconName == "globe")
        #expect(MainSection.audioDictation.iconName == "waveform.and.mic")
        #expect(MainSection.typing.iconName == "keyboard")
        #expect(MainSection.clipboard.iconName == "doc.on.clipboard")
    }

    @Test func audioKeepsItsRawValue() {
        #expect(MainSection.audioDictation.rawValue == "audioDictation")
    }

    /// `section.typingTest` and `--ui-testing-open=settings.typing` depend on these.
    @Test func typingRawValues() {
        #expect(MainSection.typing.rawValue == "typing")
        #expect(MainSection.typingTest.rawValue == "typingTest")
        #expect(MainSection.clipboard.rawValue == "clipboard")
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
