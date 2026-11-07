import SwiftUI

extension DS {
    /// Local models table, option A (Roman 2026-11-07, replaces D12): columns sized by their content in
    /// the 713.5 column (build-vs-prototype/options.html). The delete question opens in a popover on the
    /// trash button, so Actions only fits "Download". Translation is the flexible column.
    enum ModelTable {
        static let model: CGFloat = 126
        static let live: CGFloat = 62
        static let translation: CGFloat = 180
        static let languages: CGFloat = 76.5
        static let speed: CGFloat = 53
        static let accuracy: CGFloat = 67
        static let size: CGFloat = 56.5
        static let actions: CGFloat = 90.5
        static let cellPaddingV: CGFloat = 7
        static let cellPaddingH: CGFloat = 6
        static let font = SwiftUI.Font.system(size: 12)
        static let modelFont = SwiftUI.Font.system(size: 12, weight: .semibold)
    }
}

/// Filter row, table, legend and speaker note of Settings > Local models (design-spec 7.10).
struct ModelTable: View {
    @Bindable var model: LocalModelsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow.padding(.bottom, DS.Space.sm)
            table
            legend.padding(.top, DS.Space.md)
            Text("No local model labels speakers. Diduny labels them on this Mac after Stop; see Audio.")
                .font(DS.ModelTable.font)
                .foregroundStyle(DS.Palette.secondary)
                .padding(.top, DS.Space.sm)
                .accessibilityIdentifier("models.speakerNote")
        }
    }

    // MARK: Filter

    private var filterRow: some View {
        HStack(spacing: 10) {
            Text("Show models that can").font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
                .lineLimit(1).fixedSize() // one line; the pop-ups give way (build-vs-prototype)
            Picker("Show models that can", selection: $model.modeFilter) {
                ForEach(LocalModelModeFilter.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("models.filter.mode")
            Text("in").font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
            Picker("in", selection: $model.languageFilter) {
                Text("any language").tag(String?.none)
                ForEach(model.languageOptions, id: \.self) { code in
                    Text(verbatim: EngineLanguages.name(of: EngineLanguage(code))).tag(Optional(code))
                }
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("models.filter.language")
            Spacer(minLength: 0)
            Picker("Sort", selection: $model.sort) {
                ForEach(LocalModelSort.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("models.sort")
        }
    }

    // MARK: Table

    private var table: some View {
        let rows = model.rows
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow(alignment: .bottom) {
                header("Model", DS.ModelTable.model)
                header("Live text", DS.ModelTable.live)
                header("Translation", nil)
                header("Languages", DS.ModelTable.languages)
                header("Speed", DS.ModelTable.speed)
                header("Accuracy", DS.ModelTable.accuracy)
                header("Size", DS.ModelTable.size)
                cell(DS.ModelTable.actions) { Color.clear.frame(height: 1) }
            }
            hairline
            if rows.isEmpty {
                Text("No local model does this. Diduny Cloud translates between 60 languages, live.")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .padding(.vertical, DS.ModelTable.cellPaddingV)
                    .padding(.horizontal, DS.ModelTable.cellPaddingH)
                    .gridCellColumns(8)
                    .accessibilityIdentifier("models.empty")
                hairline
            }
            ForEach(rows) { row in
                modelRow(row)
                hairline
            }
        }
        .font(DS.ModelTable.font)
        .foregroundStyle(DS.Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.table")
    }

    private var hairline: some View {
        Rectangle().fill(DS.Palette.line).frame(height: 1).gridCellColumns(8)
    }

    @ViewBuilder private func modelRow(_ row: LocalModelRow) -> some View {
        let cellID = { (column: String) in "models.cell.\(row.id).\(column)" }
        GridRow(alignment: .center) {
            cell(DS.ModelTable.model) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.name).font(DS.ModelTable.modelFont)
                    if row.isRecommended {
                        Text("Recommended").font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .help(row.help ?? "")
            }
            // One element per row: the name and "Recommended" would otherwise both carry the id.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("models.row.\(row.id)")
            cell(DS.ModelTable.live) { marks([row.live], column: "Live text", row: row) }
                .accessibilityIdentifier(cellID("live"))
            cell(nil) { marks(row.translation, column: "Translation", row: row) }
                .accessibilityIdentifier(cellID("translation"))
            cell(DS.ModelTable.languages) { ModelLanguagesLink(row: row, yourLanguages: model.yourLanguages) }
            cell(DS.ModelTable.speed) { number(row.speedText) }.accessibilityIdentifier(cellID("speed"))
            cell(DS.ModelTable.accuracy) { number(row.accuracyText) }.accessibilityIdentifier(cellID("accuracy"))
            cell(DS.ModelTable.size) { number(row.sizeText) }.accessibilityIdentifier(cellID("size"))
            cell(DS.ModelTable.actions) { ModelActionsCell(row: row, state: model.action(for: row), model: model) }
        }
    }

    private func header(_ title: LocalizedStringKey, _ width: CGFloat?) -> some View {
        cell(width) {
            Text(title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Fixed width including the 7 x 6 padding; nil = the flexible column.
    private func cell(_ width: CGFloat?, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.vertical, DS.ModelTable.cellPaddingV)
            .padding(.horizontal, DS.ModelTable.cellPaddingH)
            .frame(width: width, alignment: .leading)
            .frame(minWidth: width == nil ? DS.ModelTable.translation : nil,
                   maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func number(_ text: String) -> some View {
        Text(verbatim: text).monospacedDigit().lineLimit(1).fixedSize()
    }

    /// Marks side by side, 12 apart, each with its subline; one accessibility element (spec 4.8).
    private func marks(_ marks: [ModelCellMark], column: String, row: LocalModelRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                VStack(alignment: .leading, spacing: 2) {
                    CapabilityMark(kind: mark.kind)
                    if let subline = mark.subline {
                        Text(verbatim: subline).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                            .lineSpacing(DS.Font.LineSpacing.tableSubline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(String(localized: String.LocalizationValue(column))), \(row.name): "
                + marks.map { [Self.markLabel($0.kind), $0.subline].compactMap { $0 }.joined(separator: ", ") }
                .joined(separator: ". ")))
    }

    static func markLabel(_ kind: CapabilityMark.Kind) -> String {
        switch kind {
        case .yes: String(localized: "Yes")
        case .byDiduny: String(localized: "By Diduny")
        case .no: String(localized: "No")
        }
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 22) {
            legendItem(.yes, "The engine does it")
            legendItem(.byDiduny,
                       "By Diduny: the engine makes the text, Diduny translates it into any of 60 languages. Needs a Diduny account and uses its quota")
            legendItem(.no, "Not available")
        }
        .font(DS.ModelTable.font)
        .foregroundStyle(DS.Palette.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("models.legend")
    }

    private func legendItem(_ kind: CapabilityMark.Kind, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            CapabilityMark(kind: kind, size: DS.Size.legendMark)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Languages cell: a link that lists the languages by name, or plain "English" (changes/04 §4).
/// Interim list in a native popover until WP-56's `LanguageListPopup` lands.
private struct ModelLanguagesLink: View {
    let row: LocalModelRow
    let yourLanguages: [String]
    @State private var isShown = false

    private var identifier: String { "models.cell.\(row.id).languages" }

    var body: some View {
        switch row.languages {
        case .englishOnly:
            Text("English").accessibilityIdentifier(identifier)
        case let .list(title, list):
            link(title)
                .help(list.languages.map { EngineLanguages.name(of: $0) }.joined(separator: ", "))
                .popover(isPresented: $isShown, arrowEdge: .bottom) { popover(list) }
        case .system:
            link("macOS")
                .popover(isPresented: $isShown, arrowEdge: .bottom) { popover(.system) }
        }
    }

    private func link(_ title: String) -> some View {
        InlineLink(title: LocalizedStringKey(title), showsChevron: true) { isShown = true }
            .accessibilityLabel(Text(String(format: String(localized: "%@ languages"), row.name)))
            .accessibilityValue(Text(verbatim: title))
            .accessibilityIdentifier(identifier)
    }

    private var engineTitle: String {
        if case .whisper = row.kind { return "Whisper" }
        return row.name
    }

    private func popover(_ list: EngineLanguageList) -> some View {
        let mine = Set(list.marked(by: yourLanguages).map(\.code))
        let names = list.languages.map { (code: $0.code, name: EngineLanguages.name(of: $0)) }
        let note: LocalizedStringKey = switch row.kind {
        case .whisper: "Accuracy differs a lot between languages. English-only models do English alone. Cantonese needs a Large v3 model."
        case .parakeet: "European languages. Transcription only."
        case .appleSpeech: "Apple Speech uses the dictation languages installed in macOS System Settings, so the list depends on this Mac."
        }
        return VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            Text(verbatim: engineTitle).font(DS.Font.headline)
            if let count = list.count {
                Text(String(format: String(localized: "%lld languages"), count))
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                              alignment: .leading, spacing: 0) {
                        ForEach(names, id: \.code) { entry in
                            Text(verbatim: entry.name)
                                .font(mine.contains(entry.code) ? DS.Font.contentStrong : DS.Font.content)
                                .foregroundStyle(mine.contains(entry.code) ? DS.Palette.accentText : DS.Palette.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: DS.Popup.bodyMaxHeight)
            } else {
                Text("Set in macOS").font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
            }
            Group {
                if list.count != nil { Text("Your languages are in crimson. ") + Text(note) } else { Text(note) }
            }
            .font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Panel.padding)
        .frame(width: DS.Popup.width)
        .accessibilityIdentifier("popup.languages.\(row.isWhisper ? EngineID.whisper.rawValue : row.id)")
    }
}
