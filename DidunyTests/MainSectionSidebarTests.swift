import KeyboardShortcuts
import Testing
@testable import Diduny

/// T5-SB-01 and T5-HK-41 (panels redesign WP-50).
/// Main actor: a shortcut's text reads the keyboard layout (Text Input Sources), which traps off the
/// main thread on the macOS 26 runner. The app builds it in the SwiftUI body, on the main actor.
@MainActor
struct MainSectionSidebarTests {
    @Test func mainItemsInOrder() {
        #expect(MainSection.mainItems == [.overview, .recordings, .notes, .benchmark, .typingTest])
    }

    @Test func settingsItemsInOrder() {
        #expect(MainSection.settingsItems == [
            .general, .modes, .languages, .audioDictation, .meetings, .notesSettings,
            .models, .providers, .shortcuts, .account, .about,
        ])
    }

    @Test func labels() {
        let labels = (MainSection.mainItems + MainSection.settingsItems).map(\.label)
        #expect(labels == [
            "Overview", "Recordings", "Notes", "Benchmark", "Typing test",
            "General", "Modes", "Languages", "Audio", "Calendar & meetings", "Notes settings",
            "Local models", "Providers", "Shortcuts", "Account", "About",
        ])
    }

    @Test func newItemIcons() {
        #expect(MainSection.modes.iconName == "slider.horizontal.3")
        #expect(MainSection.languages.iconName == "globe")
        #expect(MainSection.audioDictation.iconName == "waveform.and.mic")
    }

    @Test func audioKeepsItsRawValue() {
        #expect(MainSection.audioDictation.rawValue == "audioDictation")
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
