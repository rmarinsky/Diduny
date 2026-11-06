import SwiftUI

extension DS {
    /// Picker menu metrics (design-spec 4.2, 3.2).
    enum Menu {
        static let width: CGFloat = 262
        static let maxHeight: CGFloat = 320
        /// Inside the 1 pt border.
        static let padding: CGFloat = DS.Space.xs
        static let inset: CGFloat = padding + DS.Panel.borderWidth
        /// 252: rows and the search field fill the card.
        static let rowWidth: CGFloat = width - inset * 2
        static let rowVerticalPadding: CGFloat = 5
        static let rowHorizontalPadding: CGFloat = DS.Space.sm
        static let groupHeaderTop: CGFloat = 6
        static let groupHeaderBottom: CGFloat = 2
        /// 11 pt at line height 1.4; with 6 + 2 padding the header is 23.4 (`DS.Size.menuGroupHeader`).
        static let groupHeaderLineHeight: CGFloat = DS.Size.menuGroupHeader - groupHeaderTop - groupHeaderBottom
        static let searchGap: CGFloat = 2
        static let searchHorizontalPadding: CGFloat = DS.Space.sm
        static let disabledOpacity: Double = 0.5
        /// SwiftUI draws an 11 pt line 14 high; the prototype's line box is 13.1. Trimming 0.5 above and below
        /// the subline keeps a row with a one-line subline at 38 (`DS.Size.menuRowWithSubline`).
        static let sublineTrim: CGFloat = 0.5
    }
}

// MARK: - Model

struct PickerMenuRow: Equatable, Identifiable, Sendable {
    /// Stable id; the accessibility identifier is `pickerMenu.row.<id>`.
    let id: String
    let title: String
    var subline: String?
    /// A disabled row stays in its group at opacity 0.5 with the reason as subline (decision 6).
    var isEnabled = true
}

struct PickerMenuGroup: Equatable, Identifiable, Sendable {
    /// Stable id (`cloud`, `onThisMac`, `yourLanguages`, ...); identifier `pickerMenu.group.<id>`.
    let id: String
    var header: String?
    /// Rows drawn as "Your languages": accent text, semibold.
    var isYours = false
    var rows: [PickerMenuRow]
}

struct PickerMenuLanguage: Equatable, Sendable {
    let code: String
    let name: String
}

enum PickerMenuSearch: Equatable, Sendable {
    /// Search when the list has more than `PickerMenuModel.searchThreshold` rows.
    case automatic, always, never
}

enum PickerMenuRowStyle: Equatable, Sendable {
    case plain, yours, selected, disabled
}

/// The list inside a picker menu: groups, filter, keyboard highlight and the selected row (design-spec 4.2).
/// Hidden engines are simply not passed in; a group with no rows is dropped with its header (12.4).
struct PickerMenuModel: Equatable {
    enum Move: Equatable, Sendable { case up, down }

    enum Identifier {
        static let menu = "pickerMenu"
        static let search = "pickerMenu.search"
        static let empty = "pickerMenu.empty"
        static func group(_ id: String) -> String { "pickerMenu.group.\(id)" }
        static func row(_ id: String) -> String { "pickerMenu.row.\(id)" }
    }

    static let searchThreshold = 8
    /// Language lists with this many entries or more split into "Your languages" and "All languages".
    static let yourLanguagesMinimum = 6
    static var nothingFoundTitle: String { String(localized: "Nothing found") }
    static var yourLanguagesTitle: String { String(localized: "Your languages") }
    static var allLanguagesTitle: String { String(localized: "All languages") }
    static let empty = PickerMenuModel(groups: [], selectedID: nil)

    let groups: [PickerMenuGroup]
    let selectedID: String?
    let showsSearch: Bool
    private(set) var query = ""
    private(set) var highlightedID: String?

    init(groups: [PickerMenuGroup], selectedID: String?, search: PickerMenuSearch = .automatic) {
        self.groups = groups.filter { !$0.rows.isEmpty }
        self.selectedID = selectedID
        showsSearch = switch search {
        case .always: true
        case .never: false
        case .automatic: self.groups.reduce(0) { $0 + $1.rows.count } > Self.searchThreshold
        }
        highlightedID = nil
        highlightedID = selectedIfPickable
    }

    /// Languages with the "Your languages" split (`langMenu` P:434-440). Row ids are `lang.<code>`.
    static func languages(
        _ languages: [PickerMenuLanguage],
        yours: [String],
        selectedCode: String?,
        extraGroups: [PickerMenuGroup] = []
    ) -> PickerMenuModel {
        let row = { (language: PickerMenuLanguage) in PickerMenuRow(id: languageRowID(language.code), title: language.name) }
        let groups: [PickerMenuGroup] = if languages.count < yourLanguagesMinimum {
            [PickerMenuGroup(id: "allLanguages", rows: languages.map(row))]
        } else {
            [
                PickerMenuGroup(
                    id: "yourLanguages", header: yourLanguagesTitle, isYours: true,
                    rows: yours.compactMap { code in languages.first { $0.code == code } }.map(row)
                ),
                PickerMenuGroup(
                    id: "allLanguages", header: allLanguagesTitle,
                    rows: languages.filter { !yours.contains($0.code) }.map(row)
                ),
            ]
        }
        return PickerMenuModel(
            groups: groups + extraGroups,
            selectedID: selectedCode.map(languageRowID),
            search: languages.count > searchThreshold ? .always : .never
        )
    }

    static func languageRowID(_ code: String) -> String {
        "lang.\(code)"
    }

    // MARK: Filter

    /// Groups with at least one row whose title contains the query, case-insensitive (`openMenu` P:424).
    var visibleGroups: [PickerMenuGroup] {
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let rows = group.rows.filter { $0.title.range(of: query, options: .caseInsensitive) != nil }
            guard !rows.isEmpty else { return nil }
            var filtered = group
            filtered.rows = rows
            return filtered
        }
    }

    var visibleRows: [PickerMenuRow] {
        visibleGroups.flatMap(\.rows)
    }

    var showsNothingFound: Bool {
        visibleGroups.isEmpty
    }

    mutating func updateQuery(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        highlightedID = query.isEmpty ? selectedIfPickable : pickableRows.first?.id
    }

    // MARK: Highlight and pick

    mutating func moveHighlight(_ move: Move) {
        let rows = pickableRows
        guard !rows.isEmpty else {
            highlightedID = nil
            return
        }
        guard let index = rows.firstIndex(where: { $0.id == highlightedID }) else {
            highlightedID = move == .down ? rows.first?.id : rows.last?.id
            return
        }
        let next = move == .down ? min(index + 1, rows.count - 1) : max(index - 1, 0)
        highlightedID = rows[next].id
    }

    /// Pointer hover; disabled rows take no highlight.
    mutating func highlight(_ id: String) {
        if canPick(id) { highlightedID = id }
    }

    func canPick(_ id: String) -> Bool {
        pickableRows.contains { $0.id == id }
    }

    /// What Return picks.
    var highlightedPick: String? {
        highlightedID.flatMap { canPick($0) ? $0 : nil }
    }

    func rowStyle(_ row: PickerMenuRow, in group: PickerMenuGroup) -> PickerMenuRowStyle {
        if row.id == selectedID { return .selected }
        if !row.isEnabled { return .disabled }
        return group.isYours ? .yours : .plain
    }

    private var pickableRows: [PickerMenuRow] {
        visibleRows.filter(\.isEnabled)
    }

    private var selectedIfPickable: String? {
        selectedID.flatMap { canPick($0) ? $0 : nil }
    }
}

// MARK: - State

/// The open menu: the model plus what happens on a pick. Keys come from `FloatingSurfacePanel`.
@MainActor
@Observable
final class PickerMenuState {
    var model: PickerMenuModel
    let onPick: (String) -> Void
    /// Set by the presenter: `.picked` after a pick, `.escape` on Escape.
    @ObservationIgnored var close: (FloatingSurfaceCloseReason) -> Void = { _ in }
    /// The list changed size; the presenter refits the window.
    @ObservationIgnored var onLayoutChange: (() -> Void)?

    init(model: PickerMenuModel, onPick: @escaping (String) -> Void) {
        self.model = model
        self.onPick = onPick
    }

    func handle(_ key: FloatingSurfaceKey) -> Bool {
        switch key {
        case .up: model.moveHighlight(.up)
        case .down: model.moveHighlight(.down)
        case .return: if let id = model.highlightedPick { pick(id) }
        case .escape: close(.escape)
        }
        return true
    }

    func pick(_ id: String) {
        guard model.canPick(id) else { return }
        close(.picked)
        onPick(id)
    }

    func updateQuery(_ text: String) {
        model.updateQuery(text)
        onLayoutChange?()
    }
}

// MARK: - Views

/// The menu card (design-spec 4.2): 262 wide, up to 320 high, scrolls inside. The search field scrolls with the
/// list, as in the prototype (`.menu` P:78).
struct PickerMenu: View {
    /// The presenter puts the caret in the search field once the surface is key (`focusFirstTextField`).
    let state: PickerMenuState

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.menu, style: .continuous)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if state.model.showsSearch {
                        SurfaceSearchField(
                            text: Binding(get: { state.model.query }, set: { state.updateQuery($0) }),
                            identifier: PickerMenuModel.Identifier.search
                        )
                        .padding(.bottom, DS.Menu.searchGap)
                    }
                    if state.model.showsNothingFound {
                        PickerMenuGroupHeader(
                            title: PickerMenuModel.nothingFoundTitle, identifier: PickerMenuModel.Identifier.empty
                        )
                    }
                    ForEach(state.model.visibleGroups) { group in
                        if let header = group.header {
                            PickerMenuGroupHeader(title: header, identifier: PickerMenuModel.Identifier.group(group.id))
                        }
                        ForEach(group.rows) { row in
                            PickerMenuRowView(
                                row: row,
                                style: state.model.rowStyle(row, in: group),
                                isHighlighted: state.model.highlightedID == row.id,
                                onPick: { state.pick(row.id) },
                                onHover: { state.model.highlight(row.id) }
                            )
                            .id(row.id)
                        }
                    }
                }
                .padding(DS.Menu.inset)
            }
            .onChange(of: state.model.highlightedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear {
                // The selected row of a long list starts in view; rows exist after this layout pass.
                guard let id = state.model.highlightedID else { return }
                DispatchQueue.main.async { proxy.scrollTo(id) }
            }
        }
        .frame(width: DS.Menu.width)
        .frame(maxHeight: DS.Menu.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Palette.card, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: DS.Panel.borderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

struct PickerMenuRowView: View {
    let row: PickerMenuRow
    let style: PickerMenuRowStyle
    let isHighlighted: Bool
    let onPick: () -> Void
    let onHover: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.menuRow, style: .continuous)
    }

    private var fill: Color {
        if style == .selected { return DS.Palette.accentFill }
        return isHighlighted && row.isEnabled ? DS.Palette.chip : .clear
    }

    private var titleColor: Color {
        switch style {
        // White on `accentFill` (design-spec 4.2, `.menu button.sel` P:85).
        case .selected: .white
        case .yours: DS.Palette.accentText
        case .plain, .disabled: DS.Palette.text
        }
    }

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.title)
                    .font(style == .selected || style == .yours ? DS.Font.contentStrong : DS.Font.content)
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let subline = row.subline {
                    Text(verbatim: subline)
                        .font(DS.Font.caption)
                        .foregroundStyle(style == .selected ? Color.white : DS.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, -DS.Menu.sublineTrim)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, DS.Menu.rowVerticalPadding)
            .padding(.horizontal, DS.Menu.rowHorizontalPadding)
            .frame(width: DS.Menu.rowWidth, alignment: .leading)
            .background(fill, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .opacity(row.isEnabled ? 1 : DS.Menu.disabledOpacity)
        .onHover { inside in
            if inside, row.isEnabled { onHover() }
        }
        .accessibilityIdentifier(PickerMenuModel.Identifier.row(row.id))
        .accessibilityLabel(Text(verbatim: row.title))
        .accessibilityValue(Text(verbatim: row.subline ?? ""))
        .accessibilityAddTraits(style == .selected ? .isSelected : [])
    }
}

struct PickerMenuGroupHeader: View {
    let title: String
    let identifier: String

    var body: some View {
        Text(verbatim: title)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: DS.Menu.groupHeaderLineHeight)
            .padding(.horizontal, DS.Menu.rowHorizontalPadding)
            .frame(width: DS.Menu.rowWidth, alignment: .leading)
            .padding(.top, DS.Menu.groupHeaderTop)
            .padding(.bottom, DS.Menu.groupHeaderBottom)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }
}

/// Search field of menus and popups: 27 high, `box` fill, 1 pt `line`, radius 6, placeholder "Search".
/// Fills the width it is given (252 in a menu, 434 in a popup).
struct SurfaceSearchField: View {
    @Binding var text: String
    let identifier: String

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.searchField, style: .continuous)
    }

    var body: some View {
        TextField(text: $text, prompt: Text("Search")) {
            Text("Search")
        }
        .textFieldStyle(.plain)
        .font(DS.Font.content)
        .foregroundStyle(DS.Palette.text)
        .padding(.horizontal, DS.Menu.searchHorizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: DS.Size.searchField)
        .background(DS.Palette.box, in: shape)
        .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: DS.Panel.borderWidth))
        .accessibilityIdentifier(identifier)
    }
}
