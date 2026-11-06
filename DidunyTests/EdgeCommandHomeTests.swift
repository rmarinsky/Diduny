@testable import Diduny
import Foundation
import Testing

/// Command home: "As in Settings", the one-recording pick, captions, Translate into, signed out (WP-41).
@MainActor
struct EdgeCommandHomeTests {
    private static let caps: (EngineID) -> EngineCapabilities? = EdgeCommandPanelController.engineCapabilities
    private static let enUK = TranslationLanguagePair(languageA: "en", languageB: "uk")

    private func model(
        defaults: CommandHomeDefaults = .prototype,
        target: String = "en",
        isSignedIn: Bool = true
    ) -> EdgeCommandPanelModel {
        EdgeCommandPanelModel(
            defaults: defaults, target: target, pair: Self.enUK, yourLanguages: ["en", "uk", "pl"], isSignedIn: isSignedIn
        )
    }

    private func captions(_ model: EdgeCommandPanelModel) -> [String] {
        CommandHome.tiles.map {
            CommandHome.caption(for: $0, caps: Self.caps(model.engine(for: $0)), target: model.target, pair: model.pair)
        }
    }

    @Test("The header Settings link opens Settings > Modes (02 Q2)")
    func settingsLinkOpensModes() {
        #expect(CommandHome.settingsSection == .modes)
    }

    @Test("T2-EN-01 As in Settings: each tile uses its mode default")
    func asInSettingsUsesModeDefaults() {
        let home = model(defaults: CommandHomeDefaults(
            dictation: .parakeet, translation: .appleSpeech,
            meetingSegment: .thisMac, meetingEngine: .whisper, translateMeeting: .didunyCloud
        ))

        #expect(CommandHome.tiles.map(home.engine(for:)) == [.parakeet, .appleSpeech, .whisper, .didunyCloud])
        #expect(home.consumeStart(.meeting, caps: Self.caps).segment == .thisMac)
        #expect(home.engineFieldLabel == String(localized: "Engine"))
        #expect(home.engineFieldValue == String(localized: "As in Settings"))
    }

    @Test("T2-EN-02 A pick applies to all four tiles")
    func pickAppliesToAllTiles() {
        let home = model()

        #expect(home.pickEngine(rowID: EngineID.whisper.rawValue))

        #expect(CommandHome.tiles.map(home.engine(for:)) == Array(repeating: .whisper, count: 4))
        #expect(home.engineFieldLabel == String(localized: "Engine, next recording"))
        #expect(home.engineFieldValue == "Whisper")
    }

    @Test("T2-EN-03 The pick applies to one recording")
    func pickIsConsumedByTheStart() {
        let home = model()
        home.pickEngine(rowID: EngineID.parakeet.rawValue)

        let start = home.consumeStart(.transcribe, caps: Self.caps)

        #expect(start.engine == .parakeet)
        #expect(start.isPick)
        #expect(home.pick == nil)
        #expect(home.engineFieldValue == String(localized: "As in Settings"))
        #expect(home.consumeStart(.transcribe, caps: Self.caps).engine == .didunyCloud)
    }

    @Test("T2-EN-04 The pick never writes Settings")
    func pickWritesNoSetting() {
        let watched = ["meetingTranscriptMode", "transcriptionProvider", "translationProvider",
                       "meetingRealtimeTranscriptionEnabled", "defaultTranslationTargetLanguage"]
        func snapshot() -> [String: String] {
            UserDefaults.standard.dictionaryRepresentation()
                .filter { $0.key.hasPrefix("sttJobDefault") || watched.contains($0.key) }
                .mapValues { "\($0)" }
        }
        let before = snapshot()
        let home = model()
        let controller = EdgeCommandPanelController(meetingRecordingStarter: { _ in })

        home.pickEngine(rowID: EngineID.parakeet.rawValue)
        home.pickTarget("pl")
        _ = home.consumeStart(.translate, caps: Self.caps)
        controller.pickEngineRow(EngineID.whisper.rawValue)
        controller.pickEngineRow(CommandHome.asInSettingsRowID)

        #expect(snapshot() == before)
    }

    @Test("T2-EN-05 Engine menu rows and order, ElevenLabs only with a key")
    func engineMenuRows() throws {
        func menu(hasKey: Bool) -> PickerMenuModel {
            CommandHome.engineMenu(pick: nil, caps: Self.caps) { id in
                id == .elevenLabs && !hasKey ? .needsKey : .ready
            }
        }
        let withKey = menu(hasKey: true)

        #expect(withKey.groups.map(\.id) == ["asInSettings", "cloud", "onThisMac", "providers"])
        #expect(withKey.groups.map(\.header) == [nil, String(localized: "Cloud"), String(localized: "On this Mac"), nil])
        #expect(withKey.visibleRows.map(\.id) == [
            "asInSettings", "diduny-cloud", "elevenlabs", "local-whisper", "parakeet-v3", "apple-speech", "providers",
        ])
        #expect(withKey.visibleRows.map(\.title) == [
            "As in Settings", "Diduny Cloud", "ElevenLabs", "Whisper", "Parakeet V3", "Apple Speech", "Providers...",
        ])
        #expect(withKey.visibleRows.map(\.subline) == [
            "Each mode uses its own default",
            "Live text, speaker labels, 60 languages",
            "Live text, 94 languages. Your key",
            "Live preview, 100 languages · Large v3 Turbo, recommended",
            "After Stop, 25 languages · recommended",
            "Live text, macOS languages",
            "Compare engines, add a key",
        ])
        #expect(withKey.selectedID == CommandHome.asInSettingsRowID)
        #expect(!menu(hasKey: false).visibleRows.contains { $0.id == "elevenlabs" })
    }

    @Test("Engine menu: an engine that cannot run is disabled with the reason; Intel hides Parakeet")
    func engineMenuReadiness() {
        let menu = CommandHome.engineMenu(pick: .whisper, caps: Self.caps) { id in
            switch id {
            case .didunyCloud: .noQuota
            case .parakeet: .unsupportedHardware
            case .appleSpeech: .unavailable
            default: .ready
            }
        }
        let rows = Dictionary(uniqueKeysWithValues: menu.visibleRows.map { ($0.id, $0) })

        #expect(rows["diduny-cloud"]?.isEnabled == false)
        #expect(rows["diduny-cloud"]?.subline == String(localized: "Diduny quota used up"))
        #expect(rows["apple-speech"]?.isEnabled == false)
        #expect(rows["parakeet-v3"] == nil)
        #expect(menu.selectedID == "local-whisper")
    }

    @Test("T2-EN-06 Key removed while ElevenLabs is picked")
    func removedKeyDropsThePick() {
        let home = model()
        home.pickEngine(rowID: EngineID.elevenLabs.rawValue)

        home.dropPickIfUnusable { $0 == .elevenLabs ? .needsKey : .ready }

        #expect(home.pick == nil)
    }

    @Test("T2-EN-07 Record meeting segment follows a picked engine", arguments: [
        (EngineID.didunyCloud, MeetingSegment.cloud), (.elevenLabs, .cloud),
        (.whisper, .thisMac), (.appleSpeech, .thisMac), (.parakeet, .recordOnly),
    ])
    func meetingSegmentFollowsPick(engine: EngineID, segment: MeetingSegment) {
        let home = model()
        home.pickEngine(rowID: engine.rawValue)

        #expect(home.consumeStart(.meeting, caps: Self.caps).segment == segment)
    }

    @Test("T2-EN-08 A start that is not from a tile clears a pending pick")
    func hotkeyStartClearsPick() {
        let home = model(defaults: CommandHomeDefaults(
            dictation: .appleSpeech, translation: .didunyCloud,
            meetingSegment: .cloud, meetingEngine: .didunyCloud, translateMeeting: .didunyCloud
        ))
        home.pickEngine(rowID: EngineID.parakeet.rawValue)

        home.clearPick()

        #expect(home.engine(for: .transcribe) == .appleSpeech)
    }

    @Test("T2-TL-01 Tile captions with Settings defaults")
    func captionsWithDefaults() {
        #expect(captions(model()) == ["Voice → text", "Voice → English", "System + mic", "Live · EN ↔ UK"])
    }

    @Test("T2-TL-02 Tile captions per picked engine", arguments: [
        (EngineID.didunyCloud, ["Voice → text", "Voice → English", "System + mic", "Live · EN ↔ UK"]),
        (.elevenLabs, ["Voice → text", "Voice → English", "System + mic", "After Stop · EN ↔ UK"]),
        (.whisper, ["Voice → text", "Voice → English", "System + mic", "After Stop · EN ↔ UK"]),
        (.parakeet, ["Text after Stop", "Voice → English", "System + mic", "After Stop · EN ↔ UK"]),
        (.appleSpeech, ["Voice → text", "Voice → English", "System + mic", "After Stop · EN ↔ UK"]),
    ])
    func captionsPerPick(engine: EngineID, expected: [String]) {
        let home = model()
        home.pickEngine(rowID: engine.rawValue)

        #expect(captions(home) == expected)
    }

    @Test("T2-TL-03 Mixed defaults show mixed captions")
    func mixedDefaults() {
        let home = model(defaults: CommandHomeDefaults(
            dictation: .parakeet, translation: .didunyCloud,
            meetingSegment: .cloud, meetingEngine: .didunyCloud, translateMeeting: .whisper
        ))

        #expect(captions(home).first == "Text after Stop")
        #expect(captions(home).last == "After Stop · EN ↔ UK")
    }

    @Test("T2-TI-01 Translate into list")
    func translateIntoList() {
        let menu = CommandHome.translateIntoMenu(target: "en", yourLanguages: ["en", "uk", "pl"])
        let all = menu.groups.flatMap(\.rows)
        let others = menu.groups.last?.rows.map(\.title) ?? []

        #expect(all.count == 60)
        #expect(menu.groups.first?.rows.map(\.id) == ["lang.en", "lang.uk", "lang.pl"])
        #expect(others == others.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(menu.showsSearch)
        #expect(model(target: "xx").target == "en")
    }

    @Test("T2-TI-02 Translate into sets the Translate tile only")
    func translateIntoSetsTranslateTileOnly() {
        let home = model()
        home.pickTarget("pl")

        #expect(captions(home)[1] == "Voice → \(CommandHome.languageName("pl"))")
        #expect(captions(home)[3] == "Live · EN ↔ UK")
        #expect(home.consumeStart(.translate, caps: Self.caps).targetLanguage == "pl")
        #expect(home.consumeStart(.translateMeeting, caps: Self.caps).pair == Self.enUK)
        #expect(CommandHome.translatePair(target: "pl", pair: Self.enUK, yourLanguages: ["en"]).languageB == "pl")
    }

    @Test("T2-TI-03 Translate into is kept after a start")
    func translateIntoKept() {
        let home = model()
        home.pickTarget("pl")

        _ = home.consumeStart(.translate, caps: Self.caps)
        home.clearPick()

        #expect(home.target == "pl")
    }

    @Test("T2-SO-01 Signed out disables every tile, pickers stay usable")
    func signedOutDisablesTiles() {
        let home = model(isSignedIn: false)

        #expect(!home.tilesEnabled)
        #expect(home.pickEngine(rowID: EngineID.didunyCloud.rawValue))
        home.refresh(defaults: .prototype, pair: Self.enUK, yourLanguages: ["en"], isSignedIn: true)
        #expect(home.tilesEnabled)
    }
}
