@testable import Diduny
import Foundation
import Testing

/// WP-20: the picker menu list logic (design-spec 4.2, 12.4; implementation-plan 2.2 decision 6).
struct PickerMenuModelTests {
    // MARK: - Fixtures

    private static let engines: [PickerMenuGroup] = [
        PickerMenuGroup(id: "cloud", header: "Cloud", rows: [
            PickerMenuRow(id: "diduny-cloud", title: "Diduny Cloud", subline: "Live text · speaker labels"),
            PickerMenuRow(id: "elevenlabs", title: "ElevenLabs", subline: "Live text · your key"),
        ]),
        PickerMenuGroup(id: "onThisMac", header: "On this Mac", rows: [
            PickerMenuRow(id: "local-whisper", title: "Whisper", subline: "Download a model in Settings", isEnabled: false),
            PickerMenuRow(id: "parakeet-v3", title: "Parakeet V3", subline: "Not downloaded, 480 MB"),
            PickerMenuRow(id: "apple-speech", title: "Apple Speech", subline: "Live text"),
        ]),
    ]

    private static func language(_ code: String, _ name: String) -> PickerMenuLanguage {
        PickerMenuLanguage(code: code, name: name)
    }

    private static let tenLanguages: [PickerMenuLanguage] = [
        language("en", "English"), language("uk", "Ukrainian"), language("pl", "Polish"),
        language("de", "German"), language("fr", "French"), language("es", "Spanish"),
        language("it", "Italian"), language("cs", "Czech"), language("nl", "Dutch"),
        language("pt", "Portuguese"),
    ]

    private static let fiveLanguages = Array(tenLanguages.prefix(5))

    // MARK: - Groups and headers

    @Test("Engine groups keep their headers and order")
    func engineGroupsKeepHeaders() {
        let model = PickerMenuModel(groups: Self.engines, selectedID: "diduny-cloud")

        #expect(model.visibleGroups.map(\.header) == ["Cloud", "On this Mac"])
        #expect(model.visibleGroups.map(\.id) == ["cloud", "onThisMac"])
        #expect(!model.showsNothingFound)
    }

    @Test("A group without rows is dropped, header included (hidden engines, decision 6)")
    func emptyGroupIsDropped() {
        let groups = [
            PickerMenuGroup(id: "cloud", header: "Cloud", rows: []),
            PickerMenuGroup(id: "onThisMac", header: "On this Mac", rows: [
                PickerMenuRow(id: "apple-speech", title: "Apple Speech"),
            ]),
        ]
        let model = PickerMenuModel(groups: groups, selectedID: nil)

        #expect(model.visibleGroups.map(\.id) == ["onThisMac"])
    }

    @Test("Six or more languages: Your languages first, then All languages")
    func languageListWithSixOrMoreHasTwoGroups() {
        let model = PickerMenuModel.languages(Self.tenLanguages, yours: ["uk", "en", "xx"], selectedCode: "pl")

        #expect(model.visibleGroups.map(\.header) == [PickerMenuModel.yourLanguagesTitle, PickerMenuModel.allLanguagesTitle])
        #expect(model.visibleGroups.map(\.id) == ["yourLanguages", "allLanguages"])
        // Your languages keep the person's own order and skip codes the list does not offer.
        #expect(model.visibleGroups[0].rows.map(\.id) == ["lang.uk", "lang.en"])
        #expect(model.visibleGroups[0].isYours)
        #expect(model.visibleGroups[1].rows.map(\.id).first == "lang.pl")
        #expect(!model.visibleGroups[1].rows.map(\.id).contains("lang.uk"))
        #expect(!model.visibleGroups[1].isYours)
        #expect(model.selectedID == "lang.pl")
    }

    @Test("Under six languages: one group with no header")
    func languageListUnderSixHasOneGroup() {
        let model = PickerMenuModel.languages(Self.fiveLanguages, yours: ["uk"], selectedCode: "en")

        #expect(model.visibleGroups.count == 1)
        #expect(model.visibleGroups[0].header == nil)
        #expect(!model.visibleGroups[0].isYours)
        #expect(model.visibleGroups[0].rows.count == 5)
    }

    @Test("Language lists show search only above eight entries")
    func languageSearchThreshold() {
        #expect(PickerMenuModel.languages(Self.tenLanguages, yours: [], selectedCode: nil).showsSearch)
        #expect(!PickerMenuModel.languages(Array(Self.tenLanguages.prefix(8)), yours: [], selectedCode: nil).showsSearch)
    }

    @Test("Automatic search: more than eight rows; always and never are kept")
    func searchRule() {
        let nine = [PickerMenuGroup(id: "g", rows: (1...9).map { PickerMenuRow(id: "\($0)", title: "Row \($0)") })]
        let eight = [PickerMenuGroup(id: "g", rows: (1...8).map { PickerMenuRow(id: "\($0)", title: "Row \($0)") })]

        #expect(PickerMenuModel(groups: nine, selectedID: nil).showsSearch)
        #expect(!PickerMenuModel(groups: eight, selectedID: nil).showsSearch)
        #expect(PickerMenuModel(groups: eight, selectedID: nil, search: .always).showsSearch)
        #expect(!PickerMenuModel(groups: nine, selectedID: nil, search: .never).showsSearch)
    }

    // MARK: - Filtering

    @Test("Typing filters titles, case-insensitive, and drops groups with no match")
    func filtering() {
        var model = PickerMenuModel.languages(Self.tenLanguages, yours: ["uk", "en"], selectedCode: nil)

        model.updateQuery("  POL ")

        #expect(model.visibleGroups.map(\.id) == ["allLanguages"])
        #expect(model.visibleRows.map(\.title) == ["Polish"])
    }

    @Test("The filter matches titles only, not sublines")
    func filterIgnoresSublines() {
        var model = PickerMenuModel(groups: Self.engines, selectedID: nil)

        model.updateQuery("speaker")

        #expect(model.showsNothingFound)
    }

    @Test("No match shows Nothing found")
    func nothingFound() {
        var model = PickerMenuModel.languages(Self.tenLanguages, yours: [], selectedCode: nil)

        model.updateQuery("zzz")

        #expect(model.visibleGroups.isEmpty)
        #expect(model.showsNothingFound)
        #expect(model.highlightedID == nil)
    }

    @Test("Clearing the query brings every row back and the highlight to the selected row")
    func clearingQuery() {
        var model = PickerMenuModel.languages(Self.tenLanguages, yours: [], selectedCode: "de")

        model.updateQuery("pol")
        model.updateQuery("")

        #expect(model.visibleRows.count == 10)
        #expect(model.highlightedID == "lang.de")
    }

    // MARK: - Keyboard highlight

    @Test("On open the selected row is highlighted")
    func initialHighlightIsSelected() {
        let model = PickerMenuModel(groups: Self.engines, selectedID: "parakeet-v3")

        #expect(model.highlightedID == "parakeet-v3")
    }

    @Test("A disabled selected row is not highlighted on open")
    func disabledSelectionIsNotHighlighted() {
        let model = PickerMenuModel(groups: Self.engines, selectedID: "local-whisper")

        #expect(model.highlightedID == nil)
    }

    @Test("Down and Up move across groups and skip disabled rows")
    func arrowsSkipDisabled() {
        var model = PickerMenuModel(groups: Self.engines, selectedID: "elevenlabs")

        model.moveHighlight(.down)
        #expect(model.highlightedID == "parakeet-v3")

        model.moveHighlight(.up)
        #expect(model.highlightedID == "elevenlabs")
    }

    @Test("The highlight stops at both ends")
    func arrowsClampAtEnds() {
        var model = PickerMenuModel(groups: Self.engines, selectedID: "apple-speech")

        model.moveHighlight(.down)
        #expect(model.highlightedID == "apple-speech")

        var top = PickerMenuModel(groups: Self.engines, selectedID: "diduny-cloud")
        top.moveHighlight(.up)
        #expect(top.highlightedID == "diduny-cloud")
    }

    @Test("With nothing highlighted, Down goes to the first row and Up to the last")
    func arrowsFromNothing() {
        var down = PickerMenuModel(groups: Self.engines, selectedID: nil)
        down.moveHighlight(.down)
        #expect(down.highlightedID == "diduny-cloud")

        var up = PickerMenuModel(groups: Self.engines, selectedID: nil)
        up.moveHighlight(.up)
        #expect(up.highlightedID == "apple-speech")
    }

    @Test("Typing moves the highlight to the first enabled match")
    func typingHighlightsFirstMatch() {
        var model = PickerMenuModel(groups: Self.engines, selectedID: "diduny-cloud")

        model.updateQuery("p")

        // "Whisper" matches too, but it is disabled, so the highlight skips it.
        #expect(model.visibleRows.map(\.id) == ["local-whisper", "parakeet-v3", "apple-speech"])
        #expect(model.highlightedID == "parakeet-v3")
    }

    @Test("Hover highlights enabled rows only")
    func hoverHighlight() {
        var model = PickerMenuModel(groups: Self.engines, selectedID: nil)

        model.highlight("apple-speech")
        #expect(model.highlightedID == "apple-speech")

        model.highlight("local-whisper")
        #expect(model.highlightedID == "apple-speech")
    }

    // MARK: - Picking and the selected row

    @Test("Return picks the highlighted row")
    func returnPicksHighlight() {
        var model = PickerMenuModel(groups: Self.engines, selectedID: "diduny-cloud")
        model.moveHighlight(.down)

        #expect(model.highlightedPick == "elevenlabs")
    }

    @Test("Disabled rows cannot be picked; enabled ones can, Parakeet not downloaded included")
    func disabledRowsCannotBePicked() {
        let model = PickerMenuModel(groups: Self.engines, selectedID: nil)

        #expect(!model.canPick("local-whisper"))
        #expect(model.canPick("parakeet-v3"))
        #expect(!model.canPick("unknown"))
        #expect(model.highlightedPick == nil)
    }

    @Test("The selected row wins over the Your languages style")
    func selectedRowStyle() {
        let model = PickerMenuModel.languages(Self.tenLanguages, yours: ["uk", "en"], selectedCode: "uk")
        let yours = model.visibleGroups[0]

        #expect(model.rowStyle(yours.rows[0], in: yours) == .selected)
        #expect(model.rowStyle(yours.rows[1], in: yours) == .yours)
        let all = model.visibleGroups[1]
        #expect(model.rowStyle(all.rows[0], in: all) == .plain)
    }

    @Test("A disabled row keeps its group, order and subline reason")
    func disabledRowKeepsPlace() {
        let model = PickerMenuModel(groups: Self.engines, selectedID: nil)
        let mac = model.visibleGroups[1]

        #expect(mac.rows.map(\.id) == ["local-whisper", "parakeet-v3", "apple-speech"])
        #expect(mac.rows[0].subline == "Download a model in Settings")
        #expect(model.rowStyle(mac.rows[0], in: mac) == .disabled)
    }

    // MARK: - Menu state (keys)

    @MainActor
    @Test("Return closes the menu, then reports the pick; Escape only closes")
    func stateHandlesKeys() {
        var events: [String] = []
        let state = PickerMenuState(model: PickerMenuModel(groups: Self.engines, selectedID: "diduny-cloud")) {
            events.append("pick \($0)")
        }
        state.close = { events.append("close") }

        #expect(state.handle(.down))
        #expect(state.handle(.return))
        #expect(events == ["close", "pick elevenlabs"])

        events = []
        #expect(state.handle(.escape))
        #expect(events == ["close"])
    }

    @MainActor
    @Test("Return with nothing highlighted does nothing")
    func returnWithoutHighlight() {
        var events: [String] = []
        let state = PickerMenuState(model: PickerMenuModel(groups: Self.engines, selectedID: nil)) {
            events.append("pick \($0)")
        }
        state.close = { events.append("close") }

        #expect(state.handle(.return))
        #expect(events.isEmpty)
    }

    @Test("Menu strings ship in English and Ukrainian", arguments: ["en", "uk"])
    func stringsAreLocalized(language: String) throws {
        let path = try #require(Bundle.main.path(
            forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language
        ))
        let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])

        for key in ["Nothing found", "Your languages", "All languages", "Search", "Opens a list"] {
            let value = try #require(table[key], "\(language) is missing \(key)")
            #expect(language == "en" ? value == key : value != key, "\(language): \(key) = \(value)")
        }
    }

    // MARK: - Accessibility identifiers (test-plan 2.1)

    @Test("Identifiers follow test-plan 2.1")
    func identifiers() {
        #expect(PickerMenuModel.Identifier.menu == "pickerMenu")
        #expect(PickerMenuModel.Identifier.search == "pickerMenu.search")
        #expect(PickerMenuModel.Identifier.empty == "pickerMenu.empty")
        #expect(PickerMenuModel.Identifier.group("yourLanguages") == "pickerMenu.group.yourLanguages")
        #expect(PickerMenuModel.Identifier.row("parakeet-v3") == "pickerMenu.row.parakeet-v3")
        #expect(PickerMenuModel.Identifier.row("lang.uk") == "pickerMenu.row.lang.uk")
    }
}
