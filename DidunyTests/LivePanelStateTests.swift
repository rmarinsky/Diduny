import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// WP-30: live panel shell and dictation panel state (test-plan T1-DI-01, 04, 05, 07, 08, 09, T1-SH-07,
/// TS-CON-03 dictation). WP-31 and WP-32 add their mode cases here.
@MainActor
struct LivePanelStateTests {
    static func engine(_ id: EngineID, live: LiveText? = nil) throws -> LiveSessionEngine {
        try #require(LiveSessionEngine.make(id, liveOverride: live))
    }

    static func state(
        mode: RecordingMode = .voice,
        phase: LiveDictationOverlayPhase = .recording,
        connection: RealtimeConnectionStatus = .connected,
        engine: LiveSessionEngine?,
        output: DictationOutput = .original,
        hasText: Bool = true
    ) -> LivePanelState {
        LivePanelState(mode: mode, phase: phase, connectionStatus: connection, engine: engine, output: output, hasText: hasText)
    }

    @Test("T1-DI-04 title and icon follow Output")
    func titleAndIcon() throws {
        let cloud = try Self.engine(.didunyCloud)
        let original = Self.state(engine: cloud)
        let polish = Self.state(engine: cloud, output: .translation(targetLanguage: "pl"))
        #expect(original.title == "Dictating")
        #expect(original.icon == "mic")
        #expect(polish.title == "Translating")
        #expect(polish.icon == "globe")
    }

    @Test("T1-DI-05 body follows the engine")
    func bodyFollowsEngine() throws {
        let parakeet = Self.state(engine: try Self.engine(.parakeet), hasText: false)
        #expect(parakeet.body == .calm(
            title: "Recording", detail: "No live text with Parakeet V3. The text is pasted after Stop."
        ))
        #expect(Self.state(engine: try Self.engine(.didunyCloud), output: .translation(targetLanguage: "pl")).body == .transcript)
        #expect(Self.state(engine: try Self.engine(.appleSpeech), output: .translation(targetLanguage: "pl")).body == .transcript)
    }

    @Test("T1-DI-08 status for an engine without live text")
    func statusWithoutLiveText() throws {
        #expect(Self.state(engine: try Self.engine(.parakeet)).status == .plain("Recording · no live text"))
        #expect(Self.state(engine: try Self.engine(.didunyCloud)).status == .live("Recording live"))
        #expect(Self.state(connection: .connecting, engine: try Self.engine(.didunyCloud)).status == .plain("Connecting"))
    }

    @Test("T1-DI-09 ElevenLabs planned for after Stop uses the no-live rows")
    func elevenLabsAfterStop() throws {
        let state = Self.state(engine: try Self.engine(.elevenLabs, live: LiveText.none), hasText: false)
        #expect(state.caption == "Text after Stop")
        #expect(state.status == .plain("Recording · no live text"))
        #expect(state.body == .calm(title: "Recording", detail: "No live text with ElevenLabs. The text is pasted after Stop."))
        #expect(Self.state(engine: try Self.engine(.elevenLabs)).caption == "Text as you speak")
    }

    @Test("Caption per Output and engine kind (01 §4 item 5)")
    func captions() throws {
        let pl = DictationOutput.translation(targetLanguage: "pl")
        #expect(Self.state(engine: try Self.engine(.didunyCloud)).caption == "Text as you speak")
        #expect(Self.state(engine: try Self.engine(.whisper)).caption == "Text as you speak (preview)")
        #expect(Self.state(engine: try Self.engine(.parakeet)).caption == "Text after Stop")
        #expect(Self.state(engine: try Self.engine(.didunyCloud), output: pl).caption == "Live translation")
        #expect(Self.state(engine: try Self.engine(.appleSpeech), output: pl).caption
            == "You see your words. The translation by Diduny is pasted after Stop")
        #expect(Self.state(engine: try Self.engine(.parakeet), output: pl).caption == "Text and translation by Diduny after Stop")
    }

    @Test("Copy is enabled only with text in a transcript box")
    func copyRules() throws {
        #expect(Self.state(engine: try Self.engine(.didunyCloud), hasText: true).isCopyEnabled)
        #expect(!Self.state(engine: try Self.engine(.didunyCloud), hasText: false).isCopyEnabled)
        #expect(!Self.state(engine: try Self.engine(.parakeet), hasText: true).isCopyEnabled)
    }

    @Test("T1-SH-07 Stop shows the progress row with the mode's line", arguments: [
        (RecordingMode.voice, "Finishing the last words..."),
        (RecordingMode.translation(targetLanguage: "en"), "Finishing the last words..."),
        (RecordingMode.meeting, "Saving the recording..."),
        (RecordingMode.meetingTranslation, "Saving the recording...")
    ])
    func progressLine(mode: RecordingMode, line: String) throws {
        let cloud = try Self.engine(.didunyCloud)
        #expect(Self.state(mode: mode, phase: .recording, engine: cloud).progressLine == nil)
        #expect(Self.state(mode: mode, phase: .finalizing, engine: cloud).progressLine == line)
        #expect(Self.state(mode: mode, phase: .processing, engine: cloud).progressLine == line)
    }

    @Test("Cancel hint and Stop hint text")
    func shortcutHints() {
        let hints = LivePanelShortcuts(stop: "⇧ ×2", cancel: "Esc ×2")
        #expect(hints.cancelHint == "Cancel: Esc ×2")
        #expect(hints.accessibilityHint == "Stop and process recording. ⇧ ×2 also stops. Esc ×2 cancels")
        #expect(LivePanelShortcuts(stop: nil, cancel: nil).cancelHint == nil)
    }

    @Test("T1-DI-01 Output menu groups")
    func outputMenuGroups() {
        let menu = DictationOutputMenu.model(yourLanguages: ["en", "uk", "pl", "de"], selected: .original)
        #expect(menu.groups.map(\.header) == [nil, "Translate into: your languages", "All languages"])
        #expect(menu.groups[0].rows.map(\.subline) == ["Your words, no translation"])
        #expect(menu.groups[1].rows.map(\.title) == ["English", "Ukrainian", "Polish", "German"])
        #expect(menu.groups[1].isYours)
        #expect(menu.groups[2].rows.count == SupportedLanguage.cloudLanguages.count - 4)
        #expect(menu.selectedID == "original")
        #expect(menu.showsSearch)
    }

    @Test("T1-DI-07 Output search")
    func outputSearch() {
        var menu = DictationOutputMenu.model(yourLanguages: ["en", "uk"], selected: .original)
        menu.updateQuery("pol")
        #expect(menu.visibleRows.map(\.id) == ["lang.pl"])
        menu.updateQuery("zzz")
        #expect(menu.showsNothingFound)
    }

    @Test("Output row ids round-trip")
    func rowIDs() {
        #expect(DictationOutputMenu.output(forRowID: "original") == .original)
        #expect(DictationOutputMenu.output(forRowID: "lang.uk") == .translation(targetLanguage: "uk"))
        #expect(DictationOutputMenu.rowID(.translation(targetLanguage: "uk")) == "lang.uk")
    }

    @Test("TS-CON-03 dictation panel is 300 x 312 with Original and Diduny Cloud")
    func dictationPanelSize() throws {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .voice)
        store.sessionEngine = try Self.engine(.didunyCloud)
        store.phase = .recording
        store.connectionStatus = .connected
        let view = LivePanelView(
            store: store, onCopy: {}, onStop: {}, onDismiss: {}, onMinimize: {},
            onSelectOutput: { _ in }, onDrag: {}, onDragEnd: {},
            shortcuts: LivePanelShortcuts(stop: "⌥⌘D", cancel: "Esc ×3")
        )
        .frame(width: DS.Panel.width)
        .fixedSize(horizontal: false, vertical: true)
        let size = NSHostingView(rootView: view).fittingSize
        #expect(abs(size.width - 300) <= 1, "got \(size.width)")
        #expect(abs(size.height - 312) <= 1, "got \(size.height)")
    }
}
