import SwiftUI

/// Content of an engine's language popup (03 2.2): groups sorted in the app locale, search, Your languages
/// marked in place, footer.
struct LanguagePopupModel: Equatable {
    struct Item: Equatable, Identifiable {
        let code: String
        let name: String
        let isYours: Bool
        var id: String { code }
    }

    struct Group: Equatable {
        let title: String?
        let items: [Item]
    }

    let engine: EngineID
    let title: String
    let countLabel: String
    let hasList: Bool
    private let groups: [Group]

    init(caps: EngineCapabilities, yourLanguages: [String], locale: Locale = EngineLanguages.appLocale) {
        engine = caps.id
        title = ProviderTableModel.name(of: caps.id)
        countLabel = ProviderTableModel.languagesLabel(caps)
        let list = caps.traits.languages
        let yours = Set(list.marked(by: yourLanguages).map(\.code))
        if case let .groups(source) = list {
            hasList = true
            groups = source.map { group in
                let items = group.languages.map {
                    Item(code: $0.code, name: EngineLanguages.name(of: $0, locale: locale), isYours: yours.contains($0.code))
                }
                return Group(title: group.title, items: items.sorted {
                    $0.name.compare($1.name, locale: locale) == .orderedAscending
                })
            }
        } else {
            hasList = false
            groups = []
        }
    }

    /// Case-insensitive substring filter; groups left empty are dropped with their heading.
    func groups(matching query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return items.isEmpty ? nil : Group(title: group.title, items: items)
        }
    }

    var marksAny: Bool { groups.contains { $0.items.contains(where: \.isYours) } }

    /// "Your languages are in crimson. " only when one of them is in the list (03 2.4 proposal), then the engine foot.
    var footer: String {
        let prefix = marksAny ? String(localized: "Your languages are in crimson. ") : ""
        return prefix + Self.engineFooter(engine)
    }

    static func engineFooter(_ id: EngineID) -> String {
        switch id {
        case .didunyCloud: String(localized: "Transcription and translation, any language into any other.")
        case .elevenLabs: String(localized: "Transcription only. Accuracy groups are the ones ElevenLabs publishes.")
        case .whisper: String(localized: "Accuracy differs a lot between languages. English-only models do English alone. Cantonese needs a Large v3 model.")
        case .parakeet: String(localized: "European languages. Transcription only.")
        case .appleSpeech: String(localized: "Apple Speech uses the dictation languages installed in macOS System Settings, so the list depends on this Mac.")
        }
    }

    /// Three slices filled down each column, then across (design-spec 4.9).
    static func columns(_ items: [Item], count: Int = 3) -> [[Item]] {
        let perColumn = Int((Double(items.count) / Double(count)).rounded(.up))
        guard perColumn > 0 else { return [] }
        return stride(from: 0, to: items.count, by: perColumn).map { Array(items[$0 ..< min($0 + perColumn, items.count)]) }
    }
}

/// The language popup in the shared shell (design-spec 4.9, list variant).
struct LanguageListPopup: View {
    let model: LanguagePopupModel
    let close: () -> Void
    @State private var query = ""

    var body: some View {
        if model.hasList {
            PopupShell(
                icon: "globe", title: model.title, subtitle: model.countLabel, search: $query,
                accessibilityTitle: String(localized: "\(model.title) languages"), onClose: close
            ) {
                list
            } footer: {
                Text(verbatim: model.footer)
            }
        } else {
            PopupShell(
                icon: "globe", title: model.title, subtitle: model.countLabel,
                accessibilityTitle: String(localized: "\(model.title) languages"), onClose: close
            ) {
                EmptyView()
            } footer: {
                Text(verbatim: model.footer)
            }
        }
    }

    @ViewBuilder private var list: some View {
        let groups = model.groups(matching: query)
        if groups.isEmpty {
            Text("Nothing found")
                .font(DS.Font.content)
                .foregroundStyle(DS.Palette.secondary)
                .accessibilityIdentifier("popup.empty")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if let title = group.title {
                        Text(verbatim: title)
                            .font(DS.Font.captionStrong)
                            .foregroundStyle(DS.Palette.secondary)
                            .padding(.top, index == 0 ? 0 : 10)
                            .padding(.bottom, DS.Space.xs)
                            .accessibilityAddTraits(.isHeader)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(LanguagePopupModel.columns(group.items).enumerated()), id: \.offset) { _, column in
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(column) { item in
                                    Text(verbatim: item.name)
                                        .font(item.isYours ? DS.Font.contentStrong : DS.Font.content)
                                        .foregroundStyle(item.isYours ? DS.Palette.accentText : DS.Palette.text)
                                        .frame(minHeight: 21.25, alignment: .leading)
                                        .accessibilityLabel(Text(verbatim: item.name))
                                        .accessibilityValue(item.isYours ? Text(verbatim: "yours") : Text(verbatim: ""))
                                        .accessibilityIdentifier("popup.item.\(item.code)")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("popup.group.\(group.title ?? "all")")
                }
            }
        }
    }
}
