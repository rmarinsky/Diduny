import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// Component metrics against design-spec 3.2, 4.1, 4.2 and 4.9 (implementation-plan WP-20), measured with
/// `NSHostingView.fittingSize` at ±1 pt. Fonts come from the runner, hence the tolerance.
@MainActor
struct DesignSystemMetricsTests {
    private static let tolerance: CGFloat = 1

    private static func size(_ view: some View) -> NSSize {
        NSHostingView(rootView: view).fittingSize
    }

    private static func near(_ value: CGFloat, _ expected: CGFloat) -> Bool {
        abs(value - expected) <= tolerance
    }

    private static func row(_ id: String, subline: String? = nil) -> PickerMenuRow {
        PickerMenuRow(id: id, title: "Parakeet V3", subline: subline)
    }

    // MARK: - Picker field (4.1)

    @Test("Inline picker field is 30 high, with and without a label")
    func inlineField() {
        let labelled = Self.size(
            PickerField(label: "Engine", value: "Diduny Cloud", identifier: "t", menu: { .empty }, onPick: { _ in })
                .frame(width: 274)
        )
        let bare = Self.size(
            PickerField(label: nil, value: "Diduny Cloud", identifier: "t", menu: { .empty }, onPick: { _ in })
                .frame(width: 176)
        )

        #expect(Self.near(labelled.height, 30), "got \(labelled.height)")
        #expect(Self.near(bare.height, 30), "got \(bare.height)")
    }

    @Test("Stacked picker field is 42 high, alone and inside a pair")
    func stackedField() {
        let stacked = Self.size(
            PickerField(label: "Output", value: "Ukrainian", layout: .stacked, identifier: "t",
                        menu: { .empty }, onPick: { _ in })
                .frame(width: 274)
        )
        let pair = Self.size(
            PickerField(label: "Between", value: "EN ↔ UK", layout: .stackedInPair, identifier: "t",
                        menu: { .empty }, onPick: { _ in })
                .frame(width: 130)
        )

        #expect(Self.near(stacked.height, 42), "got \(stacked.height)")
        #expect(Self.near(pair.height, 42), "got \(pair.height)")
    }

    @Test("A static picker field keeps the 30 pt height")
    func staticField() {
        let size = Self.size(PickerField(staticLabel: "Engine", value: "Diduny Cloud", identifier: "t").frame(width: 274))

        #expect(Self.near(size.height, 30), "got \(size.height)")
    }

    // MARK: - Picker menu (4.2)

    @Test("Menu row: 25 one line, 38 with a subline, 51 with a two-line subline; 252 wide")
    func menuRows() {
        let oneLine = Self.size(PickerMenuRowView(row: Self.row("a"), style: .plain, isHighlighted: false, onPick: {}, onHover: {}))
        let subline = Self.size(PickerMenuRowView(
            row: Self.row("b", subline: "After Stop, on this Mac"), style: .plain, isHighlighted: false,
            onPick: {}, onHover: {}
        ))
        let twoLines = Self.size(PickerMenuRowView(
            row: Self.row("c", subline: "Live text (preview) · no speaker labels · Large v3 Turbo, recommended"),
            style: .selected, isHighlighted: false, onPick: {}, onHover: {}
        ))

        #expect(Self.near(oneLine.height, 25), "got \(oneLine.height)")
        #expect(Self.near(subline.height, 38), "got \(subline.height)")
        #expect(Self.near(twoLines.height, 51), "got \(twoLines.height)")
        #expect(Self.near(oneLine.width, 252), "got \(oneLine.width)")
    }

    @Test("Menu group header is 23.4 high; search field 252 x 27")
    func menuHeaderAndSearch() {
        let header = Self.size(PickerMenuGroupHeader(title: "On this Mac", identifier: "t"))
        let search = Self.size(SurfaceSearchField(text: .constant(""), identifier: "t").frame(width: DS.Menu.rowWidth))

        #expect(Self.near(header.height, 23.4), "got \(header.height)")
        #expect(Self.near(header.width, 252), "got \(header.width)")
        #expect(Self.near(search.height, 27), "got \(search.height)")
    }

    @Test("Menu card: 262 wide; a header and three 38 rows measure 147.4 (design-spec 12.1.2)")
    func menuCard() {
        let model = PickerMenuModel(groups: [
            PickerMenuGroup(id: "onThisMac", header: "On this Mac", rows: [
                PickerMenuRow(id: "local-whisper", title: "Whisper", subline: "After Stop, on this Mac"),
                PickerMenuRow(id: "parakeet-v3", title: "Parakeet V3", subline: "Not downloaded, 480 MB"),
                PickerMenuRow(id: "apple-speech", title: "Apple Speech", subline: "After Stop, on this Mac"),
            ]),
        ], selectedID: "parakeet-v3")
        let size = Self.size(PickerMenu(state: PickerMenuState(model: model, onPick: { _ in })))

        #expect(Self.near(size.width, 262), "got \(size.width)")
        #expect(Self.near(size.height, 147.4), "got \(size.height)")
    }

    @Test("Menu card stops at 320 high and scrolls inside")
    func menuMaxHeight() {
        let model = PickerMenuModel.languages(
            (1...30).map { PickerMenuLanguage(code: "l\($0)", name: "Language \($0)") },
            yours: ["l1", "l2"],
            selectedCode: "l1"
        )
        let size = Self.size(PickerMenu(state: PickerMenuState(model: model, onPick: { _ in })))

        #expect(Self.near(size.width, 262), "got \(size.width)")
        #expect(Self.near(size.height, 320), "got \(size.height)")
    }

    @Test("Nothing found is one header-sized row")
    func menuNothingFound() {
        var model = PickerMenuModel(groups: [
            PickerMenuGroup(id: "g", rows: [PickerMenuRow(id: "a", title: "A")]),
        ], selectedID: nil, search: .always)
        model.updateQuery("zzz")
        let size = Self.size(PickerMenu(state: PickerMenuState(model: model, onPick: { _ in })))

        // 1 + 4 padding, search 27 + 2, header 23.4, 4 + 1 padding.
        #expect(Self.near(size.height, 62.4), "got \(size.height)")
    }

    // MARK: - Popup shell (4.9)

    @Test("Popup shell is 460 wide")
    func popupWidth() {
        let size = Self.size(
            PopupShell(icon: "globe", title: "ElevenLabs", subtitle: "94 languages", onClose: {}) {
                Text(verbatim: "English")
            } footer: {
                Text(verbatim: "Your languages are in crimson.")
            }
        )

        #expect(Self.near(size.width, 460), "got \(size.width)")
    }

    @Test("Popup body box stops at 300 high, the Change list at 260")
    func popupBodyMaxHeight() {
        let tall = VStack(spacing: 0) {
            ForEach(0..<60, id: \.self) { Text(verbatim: "Row \($0)") }
        }
        let standard = Self.size(PopupShellBody(style: .box) { tall })
        let list = Self.size(PopupShellBody(style: .list) { tall })

        #expect(Self.near(standard.height, 300), "got \(standard.height)")
        #expect(Self.near(list.height, 260), "got \(list.height)")
    }
}
