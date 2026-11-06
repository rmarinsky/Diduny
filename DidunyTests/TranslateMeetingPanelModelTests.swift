import Foundation
@testable import Diduny
import Testing

/// Translate meeting live panel copy and menus (design-spec 7.3, 12.3; T1-TM-03, -04, -08, 12.4).
@MainActor
struct TranslateMeetingPanelModelTests {
    let english = Locale(identifier: "en")
    let pair = TranslationLanguagePair(languageA: "en", languageB: "uk")

    func option(_ id: EngineID, _ name: String, _ readiness: EngineReadiness = .ready) throws -> TranslateMeetingEngineOption {
        try TranslateMeetingEngineOption(caps: EngineCaptionsTests.caps(id), name: name, readiness: readiness)
    }

    func model(engine: EngineID, name: String, pairs: [TranslationLanguagePair]? = nil, engines: [TranslateMeetingEngineOption] = []) throws -> TranslateMeetingPanelModel {
        try TranslateMeetingPanelModel(
            pair: pair, offeredPairs: pairs ?? [pair], engine: option(engine, name), engines: engines, locale: english
        )
    }

    @Test("Diduny Cloud is live: caption, original link, no calm text, live status")
    func liveCaption() throws {
        let m = try model(engine: .didunyCloud, name: "Diduny Cloud")
        #expect(m.isLive)
        #expect(m.caption == "Live · both directions · speaker labels")
        #expect(m.showsOriginalLink)
        #expect(m.calmDetail == nil)
        #expect(m.notLiveStatus == nil)
    }

    @Test("Other engines: one direction into the pair's second language, no link (12.3)", arguments: [EngineID.whisper, .elevenLabs, .parakeet, .appleSpeech])
    func afterStopCaption(_ id: EngineID) throws {
        let m = try model(engine: id, name: "X")
        #expect(!m.isLive)
        #expect(m.caption == "After Stop · everything into Ukrainian · no speaker labels")
        #expect(!m.showsOriginalLink)
        #expect(m.notLiveStatus == "Recording · no live text")
    }

    @Test("Calm sentence names the engine and the second language; cloud engines drop \"on this Mac\"")
    func calmDetail() throws {
        #expect(try model(engine: .whisper, name: "Whisper").calmDetail
            == "No live text with Whisper. It transcribes on this Mac after Stop, then Diduny translates all of it into Ukrainian. Both directions need Diduny Cloud.")
        #expect(try model(engine: .elevenLabs, name: "ElevenLabs").calmDetail
            == "No live text with ElevenLabs. It transcribes after Stop, then Diduny translates all of it into Ukrainian. Both directions need Diduny Cloud.")
    }

    @Test("Tile caption: live pair or After Stop → second language code")
    func tileCaption() throws {
        #expect(EngineCaptions.translateMeetingTileCaption(caps: try EngineCaptionsTests.caps(.didunyCloud), pair: pair) == "Live · EN ↔ UK")
        #expect(EngineCaptions.translateMeetingTileCaption(caps: try EngineCaptionsTests.caps(.whisper), pair: pair) == "After Stop → UK")
    }

    @Test("Between menu: pairs in full names, current selected, then Other languages; no search")
    func betweenMenu() throws {
        let enPl = TranslationLanguagePair(languageA: "en", languageB: "pl")
        let m = try model(engine: .didunyCloud, name: "Diduny Cloud", pairs: [pair, enPl])
        let menu = m.betweenMenu
        #expect(menu.groups.first?.header == "Both directions, between your languages")
        #expect(menu.groups.first?.rows.map(\.title) == ["English ↔ Ukrainian", "English ↔ Polish"])
        #expect(menu.selectedID == "pair.en-uk")
        #expect(menu.groups.last?.rows.map(\.id) == ["otherLanguages"])
        #expect(menu.groups.last?.rows.first?.subline == "Add them to Your languages in Settings")
        #expect(!menu.showsSearch)
        #expect(m.pair(forRowID: "pair.en-pl") == enPl)
        #expect(m.pair(forRowID: "otherLanguages") == nil)
    }

    @Test("Fewer than two Your languages: only Other languages (T1-TM-08)")
    func noPairs() throws {
        let menu = try model(engine: .didunyCloud, name: "Diduny Cloud", pairs: []).betweenMenu
        #expect(menu.groups.flatMap(\.rows).map(\.id) == ["otherLanguages"])
    }

    @Test("Engine menu: Cloud then On this Mac; no key and wrong hardware hidden; no quota disabled")
    func engineMenu() throws {
        let engines = try [
            option(.didunyCloud, "Diduny Cloud", .noQuota),
            option(.elevenLabs, "ElevenLabs", .needsKey),
            option(.whisper, "Whisper"),
            option(.parakeet, "Parakeet V3", .unsupportedHardware),
            option(.appleSpeech, "Apple Speech"),
        ]
        let menu = try model(engine: .whisper, name: "Whisper", engines: engines).engineMenu
        #expect(menu.groups.map(\.header) == ["Cloud", "On this Mac"])
        #expect(menu.groups.flatMap(\.rows).map(\.id) == ["diduny-cloud", "local-whisper", "apple-speech"])
        let cloud = try #require(menu.groups.first?.rows.first)
        #expect(!cloud.isEnabled)
        #expect(cloud.subline == "Diduny quota used up")
        #expect(menu.groups.last?.rows.last?.subline == "After Stop, by Diduny, into one language")
        #expect(menu.selectedID == "local-whisper")
    }
}
