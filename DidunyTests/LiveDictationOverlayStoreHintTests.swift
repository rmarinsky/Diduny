import AppKit
@testable import Diduny
import Foundation
import KeyboardShortcuts
import Testing

/// Stop and cancel hints read the live settings and keys (test-plan T1-SH-01 to T1-SH-04).
/// Expected chord text comes from the package's own description, so the test does not depend on
/// the keyboard layout; what it checks is which name, count and key the store reads.
@MainActor
final class LiveDictationOverlayStoreHintTests {
    private let box = IsolatedSettings("LiveDictationOverlayStoreHintTests")
    private let registrar = FakeHotkeyRegistrar()
    private var settings: SettingsStorage { box.settings }

    private func makeStore(_ mode: RecordingMode, phase: LiveDictationOverlayPhase = .recording) -> LiveDictationOverlayStore {
        let store = LiveDictationOverlayStore()
        store.settings = box.settings
        store.hotkeys = registrar
        store.reset(mode: mode)
        store.phase = phase
        return store
    }

    private func text(_ name: KeyboardShortcuts.Name) -> String {
        String(describing: registrar.getShortcut(for: name)!)
    }

    @Test("T1-SH-01 Stop hint per mode and press count")
    func stopHintPerMode() {
        settings.pushToTalkKey = .rightShift
        settings.pushToTalkToggleEnabled = true
        settings.pushToTalkToggleTapCount = 2
        #expect(makeStore(.voice).stopShortcutHint == "⇧ ×2")

        settings.pushToTalkToggleEnabled = false
        #expect(makeStore(.voice).stopShortcutHint == text(.toggleRecording))

        settings.translationPushToTalkToggleEnabled = false
        #expect(makeStore(.translation()).stopShortcutHint == text(.toggleTranslation))
        #expect(makeStore(.meeting).stopShortcutHint == text(.toggleMeetingRecording))
        #expect(makeStore(.meetingTranslation).stopShortcutHint == text(.toggleMeetingTranslation))
        #expect(makeStore(.fileTranscription).stopShortcutHint == nil)

        #expect(text(.toggleRecording).hasPrefix("⌥⌘"), "Default chord ⌥⌘D")
    }

    @Test("T1-SH-02 the cancel hint shows the stored cancel keys")
    func cancelHintShowsStoredKey() {
        settings.escapeCancelShortcut = RecordingCancelShortcut(
            keyCode: KeyCode.a,
            modifiersRawValue: NSEvent.ModifierFlags.command.rawValue,
            keyLabel: "A"
        )
        settings.escapeCancelPressCount = 3
        let store = makeStore(.voice)
        #expect(store.cancelShortcutHint == "⌘A ×3")

        settings.escapeCancelShortcut = .defaultShortcut
        settings.escapeCancelPressCount = 1
        #expect(store.cancelShortcutHint == "Esc")

        settings.escapeCancelEnabled = false
        #expect(store.cancelShortcutHint == nil)
    }

    @Test("T1-SH-03 hints follow a shortcut change at once")
    func hintsFollowShortcutChange() {
        settings.pushToTalkToggleEnabled = false
        let store = makeStore(.voice)
        let newKeys = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])

        registrar.setShortcut(newKeys, for: .toggleRecording)
        #expect(store.stopShortcutHint == String(describing: newKeys))
    }

    @Test("T1-SH-04 no hints outside recording")
    func noHintsOutsideRecording() {
        let store = makeStore(.voice, phase: .finalizing)
        #expect(store.stopShortcutHint == nil)
        #expect(store.cancelShortcutHint == nil)
    }
}

/// The status menu's recording items show the live shortcut (test-plan T5-HK-40).
@MainActor
final class StatusMenuShortcutTests {
    private let registrar = FakeHotkeyRegistrar()

    private func builder(reusing items: [NSMenuItem]? = nil) -> StatusMenuBuilder {
        let connection = CalendarConnection(
            defaults: UserDefaults(suiteName: "StatusMenuShortcutTests-\(UUID())")!,
            authorize: { false },
            read: { _ in ScheduledCalendarSnapshot(calendars: [], meetings: []) }
        )
        var builder = StatusMenuBuilder(
            appState: AppState(), audioDeviceManager: AudioDeviceManager(), connection: connection,
            actions: .init(
                toggleRecording: {}, toggleTranslation: {}, toggleMeeting: {}, toggleMeetingTranslation: {},
                batchFilesAndURLs: {}, openMainWindow: { _ in }, checkForUpdates: {}
            )
        )
        builder.hotkeys = registrar
        builder.reusedRecordingItems = items
        return builder
    }

    @Test("T5-HK-40 menu bar items show the live shortcut and follow a change")
    func menuItemsFollowShortcut() throws {
        let items = builder().recordingItems()
        let dictation = try #require(items.first)
        let defaultKeys = try #require(registrar.getShortcut(for: .toggleRecording))
        #expect(dictation.keyEquivalent == defaultKeys.nsMenuItemKeyEquivalent)
        #expect(dictation.keyEquivalentModifierMask == [.command, .option])

        let newKeys = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
        registrar.setShortcut(newKeys, for: .toggleRecording)
        _ = builder(reusing: items).recordingItems()
        #expect(dictation.keyEquivalent == newKeys.nsMenuItemKeyEquivalent)
    }
}
