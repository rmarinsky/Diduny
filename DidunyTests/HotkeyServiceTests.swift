@testable import Diduny
import Foundation
import KeyboardShortcuts
import Testing

/// `HotkeyService` with a fake registrar, a manual clock and its own settings (test-plan 4.9).
@MainActor
final class HotkeyServiceTests {
    private let box = IsolatedSettings("HotkeyServiceTests")
    private let registrar = FakeHotkeyRegistrar()
    private let clock = ManualClock(100)
    private let center = NotificationCenter()
    private lazy var session = ShortcutCaptureSession(registrar: registrar, notifications: center)
    private lazy var sut = HotkeyService(
        settings: box.settings,
        registrar: registrar,
        clock: clock,
        captureSession: session,
        shortcutChanges: center
    )

    private var settings: SettingsStorage { box.settings }

    // MARK: - Mode and text hotkeys

    @Test("T5-HK-06 each name reaches its own handler with the count read at press time")
    func eachNameReachesItsHandler() {
        var calls: [String] = []
        sut.registerRecordingHotkey { calls.append("dictation") }
        sut.registerTranslationHotkey { calls.append("translation") }
        sut.registerMeetingHotkey { calls.append("meeting") }
        sut.registerMeetingTranslationHotkey { calls.append("meetingTranslation") }
        sut.registerTranslateSelectedTextHotkey { calls.append("translateSelected") }

        let names: [(KeyboardShortcuts.Name, String)] = [
            (.toggleRecording, "dictation"),
            (.toggleTranslation, "translation"),
            (.toggleMeetingRecording, "meeting"),
            (.toggleMeetingTranslation, "meetingTranslation"),
            (.translateSelectedText, "translateSelected")
        ]
        for (name, expected) in names {
            calls = []
            clock.advance(by: 1)
            registrar.fire(name)
            #expect(calls == [expected], "\(name.rawValue)")
        }

        settings.recordingHotkeyPressCount = 1
        calls = []
        clock.advance(by: 1)
        registrar.fire(.toggleRecording)
        #expect(calls == ["dictation"])

        settings.recordingHotkeyPressCount = 2
        calls = []
        clock.advance(by: 1)
        registrar.fire(.toggleRecording)
        #expect(calls.isEmpty, "2x needs a second press")
        clock.advance(by: 0.2)
        registrar.fire(.toggleRecording)
        #expect(calls == ["dictation"])
    }

    @Test("T5-HK-07 unregister disables the name and drops the handler")
    func unregisterDisablesAndResets() {
        var calls = 0
        sut.registerRecordingHotkey { calls += 1 }
        sut.unregisterRecordingHotkey()

        #expect(registrar.calls.contains(.disable(.toggleRecording)))
        registrar.fire(.toggleRecording)
        #expect(calls == 0)
        #expect(!registrar.isEnabled(.toggleRecording))
    }

    @Test("T5-HK-09 a changed shortcut fires, the old one does not")
    func changedShortcutFires() {
        var calls = 0
        sut.registerRecordingHotkey { calls += 1 }
        let oldKeys = KeyboardShortcuts.Shortcut(.d, modifiers: [.command, .option])
        let newKeys = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])

        registrar.setShortcut(newKeys, for: .toggleRecording)
        registrar.fire(keys: oldKeys)
        #expect(calls == 0)
        registrar.fire(keys: newKeys)
        #expect(calls == 1)
    }

    @Test("Registering again replaces the handler instead of adding a second one")
    func registeringAgainDoesNotStackHandlers() {
        var chapters = 0
        sut.registerChapterHotkey { chapters += 1 }
        sut.unregisterChapterHotkey()
        sut.registerChapterHotkey { chapters += 1 }

        registrar.fire(.addMeetingChapter)
        #expect(chapters == 1)
        #expect(registrar.handlerCount(for: .addMeetingChapter) == 1)
    }

    // MARK: - Switches

    @Test(
        "T5-HK-08 switch off disables the name and keeps the keys",
        arguments: [ShortcutRow.addMeetingChapter, .translateSelectedText, .historyPalette]
    )
    func switchOffKeepsKeys(row: ShortcutRow) throws {
        let name = try #require(row.hotkeyName)
        var calls = 0
        register(row) { calls += 1 }
        let keys = registrar.getShortcut(for: name)

        settings.setShortcutEnabled(false, for: row)
        sut.refreshSwitches()
        #expect(registrar.calls.contains(.disable(name)))
        #expect(registrar.getShortcut(for: name) == keys)
        registrar.fire(name)
        #expect(calls == 0)

        settings.setShortcutEnabled(true, for: row)
        sut.refreshSwitches()
        #expect(registrar.calls.contains(.enable(name)))
        clock.advance(by: 1)
        registrar.fire(name)
        #expect(calls == 1)
    }

    @Test("A switched-off name stays off when its keys are recorded again")
    func recordingNewKeysKeepsSwitchOff() {
        settings.historyPaletteHotkeyEnabled = false
        sut.registerHistoryPaletteHotkey {}
        #expect(!registrar.isEnabled(.toggleHistoryPalette))

        // The package registers new keys at once; the service turns them off again.
        registrar.setShortcut(.init(.j, modifiers: [.command, .option]), for: .toggleHistoryPalette)
        center.post(
            name: HotkeyService.packageShortcutDidChange,
            object: nil,
            userInfo: ["name": KeyboardShortcuts.Name.toggleHistoryPalette]
        )
        #expect(!registrar.isEnabled(.toggleHistoryPalette))
    }

    @Test("The copied notification name still matches KeyboardShortcuts (pinned 2.4.0)")
    func packageNotificationNameMatches() {
        // A probe name with no default and an unlikely chord; removed again at the end.
        let probe = KeyboardShortcuts.Name("wp15NotificationProbe.\(UUID().uuidString)")
        var received: [KeyboardShortcuts.Name] = []
        let token = NotificationCenter.default.addObserver(
            forName: HotkeyService.packageShortcutDidChange, object: nil, queue: nil
        ) { notification in
            if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name, name == probe {
                received.append(name)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        KeyboardShortcuts.setShortcut(.init(.f19, modifiers: [.control, .option, .command]), for: probe)
        KeyboardShortcuts.setShortcut(nil, for: probe)
        #expect(received == [probe, probe], "If this fails, the package renamed shortcutByNameDidChange")
    }

    // MARK: - Capture session

    @Test("A name unregistered during capture stays off after the capture ends")
    func unregisteredDuringCaptureStaysOff() {
        sut.registerChapterHotkey {}
        sut.registerRecordingHotkey {}
        session.begin()
        #expect(!registrar.isEnabled(.addMeetingChapter))

        sut.unregisterChapterHotkey()
        session.end()
        #expect(!registrar.isEnabled(.addMeetingChapter), "The meeting stopped during capture")
        #expect(registrar.isEnabled(.toggleRecording), "A name still registered comes back")
    }

    @Test("A name registered during capture goes live only when the capture ends")
    func registeredDuringCaptureWaits() {
        var chapters = 0
        session.begin()
        sut.registerChapterHotkey { chapters += 1 }
        #expect(!registrar.isEnabled(.addMeetingChapter))
        registrar.fire(.addMeetingChapter)
        #expect(chapters == 0)

        session.end()
        #expect(registrar.isEnabled(.addMeetingChapter))
        registrar.fire(.addMeetingChapter)
        #expect(chapters == 1)
    }

    @Test("A switched-off name stays off after a capture")
    func switchedOffStaysOffAfterCapture() {
        settings.translateSelectedTextHotkeyEnabled = false
        sut.registerTranslateSelectedTextHotkey {}
        session.begin()
        session.end()
        #expect(!registrar.isEnabled(.translateSelectedText))
    }

    // MARK: - Chapter

    @Test("T5-CH-01 the chapter hotkey is registered only during a meeting")
    func chapterRegisteredOnlyDuringMeeting() {
        #expect(!registrar.isEnabled(.addMeetingChapter))
        sut.registerChapterHotkey {}
        #expect(registrar.isEnabled(.addMeetingChapter))
        sut.unregisterChapterHotkey()
        #expect(registrar.calls.contains(.disable(.addMeetingChapter)))
        #expect(!registrar.isEnabled(.addMeetingChapter))
    }

    @Test("T5-CH-02 chapter press count and switch")
    func chapterPressCountAndSwitch() {
        var chapters = 0
        settings.addMeetingChapterPressCount = 2
        sut.registerChapterHotkey { chapters += 1 }

        registrar.fire(.addMeetingChapter)
        #expect(chapters == 0)
        clock.advance(by: 0.2)
        registrar.fire(.addMeetingChapter)
        #expect(chapters == 1)

        sut.unregisterChapterHotkey()
        settings.addMeetingChapterHotkeyEnabled = false
        sut.registerChapterHotkey { chapters += 1 }
        #expect(!registrar.isEnabled(.addMeetingChapter))
        registrar.fire(.addMeetingChapter)
        #expect(chapters == 1)
    }

    // MARK: - Translate selected text and history palette

    @Test("T5-TS-01 translate selected text reaches its handler")
    func translateSelectedTextReachesHandler() {
        var calls = 0
        sut.registerTranslateSelectedTextHotkey { calls += 1 }
        registrar.fire(.translateSelectedText)
        #expect(calls == 1)
    }

    @Test("T5-TS-02 translate selected text switch off")
    func translateSelectedTextSwitchOff() {
        var calls = 0
        settings.translateSelectedTextHotkeyEnabled = false
        sut.registerTranslateSelectedTextHotkey { calls += 1 }
        registrar.fire(.translateSelectedText)
        #expect(calls == 0)
        #expect(!registrar.isEnabled(.translateSelectedText))
    }

    @Test("T5-HP-01 history palette handler, count and switch")
    func historyPaletteCountAndSwitch() {
        var toggles = 0
        sut.registerHistoryPaletteHotkey { toggles += 1 }

        registrar.fire(.toggleHistoryPalette)
        clock.advance(by: 0.1)
        registrar.fire(.toggleHistoryPalette)
        #expect(toggles == 2, "1x by default: every press")

        settings.historyPalettePressCount = 2
        clock.advance(by: 1)
        registrar.fire(.toggleHistoryPalette)
        #expect(toggles == 2)
        clock.advance(by: 0.2)
        registrar.fire(.toggleHistoryPalette)
        #expect(toggles == 3)

        settings.historyPaletteHotkeyEnabled = false
        sut.refreshSwitches()
        clock.advance(by: 1)
        registrar.fire(.toggleHistoryPalette)
        #expect(toggles == 3)
    }

    private func register(_ row: ShortcutRow, handler: @escaping () -> Void) {
        switch row {
        case .addMeetingChapter: sut.registerChapterHotkey(handler: handler)
        case .translateSelectedText: sut.registerTranslateSelectedTextHotkey(handler: handler)
        case .historyPalette: sut.registerHistoryPaletteHotkey(handler: handler)
        case .cancelRecording, .forceSubmit, .inplaceTranslation: Issue.record("Not a HotkeyService row")
        }
    }
}
