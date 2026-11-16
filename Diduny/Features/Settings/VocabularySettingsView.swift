import PapugaKit
import SwiftUI

/// Vocabulary: what Diduny Cloud receives as `user_context` (see `SpeechUserContext`).
struct VocabularySettingsView: View {
    var settings: SettingsStorage = .shared
    var store: VocabularyStore = .shared

    @State private var terms: [String] = []
    @State private var newTerm = ""
    @State private var domain = ""
    @State private var glossary: [SpeechTranslationTerm] = []
    @State private var newSource = ""
    @State private var newTarget = ""
    @State private var usesCalendar = true
    @State private var rules: [CustomAutoReplaceRule] = []
    @State private var tab: Tab = .words

    private enum Tab { case words, decisions }

    var body: some View {
        PageScaffold(
            title: "Vocabulary",
            subtitle: "Diduny Cloud receives these words and description at the start of each recording to recognize names and terms better. Applies only to Diduny Cloud. Layout fixes never change these words.",
            trailing: {
                Picker("Vocabulary", selection: $tab) {
                    Text("Words").tag(Tab.words)
                    Text("Decisions").tag(Tab.decisions)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("vocabulary.tab")
                Button("Typing settings") { MainWindowController.shared.showWindow(section: .typing) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("vocabulary.typingSettings")
            }
        ) {
            if tab == .decisions {
                VocabularyDecisionsView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !store.extras.pending.isEmpty {
                        group("Waiting for you", first: true)
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(store.extras.pending.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { RowSeparator() }
                                    pendingRow(item)
                                }
                            }
                        }
                        .accessibilityIdentifier("vocabulary.waiting")
                        hint("Found while you typed and dictated. Nothing here is used until you add it.")
                    }
                    group("Words and names", first: store.extras.pending.isEmpty)
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            HStack(spacing: DS.Space.sm) {
                                TextField("Add a word or name", text: $newTerm)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(addTerm)
                                    .accessibilityIdentifier("vocabulary.newTerm")
                                Button("Add", action: addTerm)
                                    .disabled(newTerm.nilIfBlank == nil || terms.count >= SpeechUserContext.termsLimit)
                            }
                            .padding(DS.Space.md)
                            ForEach(terms, id: \.self) { term in
                                RowSeparator()
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: term).font(DS.Font.body)
                                        if let meta = store.meta(for: term) {
                                            Text(VocabularyText.sourceLine(meta))
                                                .font(DS.Font.meta)
                                                .foregroundStyle(DS.Palette.secondary)
                                        }
                                    }
                                    Spacer()
                                    TrashButton(accessibilityLabel: "Delete \(term)") {
                                        setTerms(terms.filter { $0 != term })
                                        store.wordDeleted(term)
                                    }
                                }
                                .padding(.horizontal, DS.Space.md)
                                .padding(.vertical, DS.Space.sm)
                            }
                        }
                    }
                    hint("\(terms.count) of 300. Write it the way it should appear in text.")

                    group("What you usually talk about")
                    TextField("What you usually talk about", text: $domain, prompt: Text(verbatim: ""), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3 ... 6)
                        .labelsHidden()
                        .onChange(of: domain) { _, new in settings.speechDomain = new }
                        .accessibilityIdentifier("vocabulary.domain")
                    hint("Empty means software development.")

                    group("Translation glossary")
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            pairRow { Text("Original") } target: { Text("Translation") } trailing: { Color.clear }
                                .font(DS.Font.meta)
                                .foregroundStyle(DS.Palette.secondary)
                            ForEach(Array(glossary.enumerated()), id: \.offset) { index, pair in
                                RowSeparator()
                                pairRow { Text(verbatim: pair.source) } target: { Text(verbatim: pair.target) } trailing: {
                                    TrashButton(accessibilityLabel: "Delete \(pair.source)") {
                                        var updated = glossary
                                        updated.remove(at: index)
                                        setGlossary(updated)
                                    }
                                }
                            }
                            RowSeparator()
                            HStack(spacing: DS.Space.sm) {
                                TextField("Original", text: $newSource).textFieldStyle(.roundedBorder).onSubmit(addPair)
                                TextField("Translation", text: $newTarget).textFieldStyle(.roundedBorder).onSubmit(addPair)
                                Button("Add", action: addPair)
                                    .disabled(newSource.nilIfBlank == nil || newTarget.nilIfBlank == nil
                                        || glossary.count >= SpeechUserContext.translationTermsLimit)
                            }
                            .padding(DS.Space.md)
                        }
                    }
                    hint("Used when translating.")

                    group("Replacements")
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            if rules.isEmpty {
                                Text("No replacements.")
                                    .font(DS.Font.meta)
                                    .foregroundStyle(DS.Palette.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, DS.Space.md)
                                    .padding(.vertical, DS.Space.sm)
                            }
                            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                                if index > 0 { RowSeparator() }
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: "\(rule.source) → \(rule.target)").font(DS.Font.body)
                                        Text("Typing").font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
                                    }
                                    Spacer()
                                    TrashButton(accessibilityLabel: "Delete \(rule.source)") { store.deleteReplacement(rule) }
                                }
                                .padding(.horizontal, DS.Space.md)
                                .padding(.vertical, DS.Space.sm)
                            }
                        }
                    }
                    .accessibilityIdentifier("vocabulary.replacements")
                    hint("A replacement changes your text as you type or dictate. It is never added without your click.")

                    group("Meetings")
                    Card(padding: 0) {
                        SettingsLineRow(title: "Use meeting title and attendee names from the calendar", kind: .toggle,
                                        showsHairline: false) {
                            SettingsSwitch(title: "Use meeting title and attendee names from the calendar", isOn: $usesCalendar)
                                .accessibilityIdentifier("vocabulary.calendar")
                        }
                        .padding(.horizontal, DS.Space.md)
                    }
                    hint("The title and names go to Diduny Cloud only for that meeting's recording.")
                }
            }
        }
        .onAppear(perform: reloadLists)
        .onChange(of: store.revision) { _, _ in reloadLists() }
        .onAppear {
            domain = settings.speechDomain
            glossary = settings.speechTranslationTerms
            usesCalendar = settings.speechUsesCalendarContext
        }
        .onChange(of: usesCalendar) { _, new in settings.speechUsesCalendarContext = new }
    }

    private func reloadLists() {
        terms = settings.speechVocabularyTerms
        rules = settings.typingCustomReplaceRules
    }

    private func pendingRow(_ item: VocabularyPendingItem) -> some View {
        HStack(spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                switch item.kind {
                case let .word(word): Text(verbatim: word).font(DS.Font.body)
                case let .replacement(from, to): Text("Replace \"\(from)\" with \"\(to)\" as you type").font(DS.Font.body)
                }
                Text(VocabularyText.reasonLine(item))
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Add") { store.accept(item) }
                .buttonStyle(.bordered)
                .disabled(item.isWord && terms.count >= SpeechUserContext.termsLimit)
                .accessibilityLabel("Add \(item.title)")
            Button("Ignore") { store.ignore(item) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Ignore \(item.title)")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }

    private func addTerm() {
        guard let term = newTerm.nilIfBlank, terms.count < SpeechUserContext.termsLimit else { return }
        if !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) { setTerms(terms + [term]) }
        newTerm = ""
    }

    private func setTerms(_ value: [String]) {
        terms = value
        settings.speechVocabularyTerms = value
    }

    private func addPair() {
        guard let source = newSource.nilIfBlank, let target = newTarget.nilIfBlank else { return }
        let pair = SpeechTranslationTerm(source: source, target: target)
        // One translation per original: a new pair for the same original replaces the old one, as it is sent.
        if let index = glossary.firstIndex(where: { $0.source.caseInsensitiveCompare(source) == .orderedSame }) {
            var updated = glossary
            updated[index] = pair
            setGlossary(updated)
        } else {
            guard glossary.count < SpeechUserContext.translationTermsLimit else { return }
            setGlossary(glossary + [pair])
        }
        newSource = ""
        newTarget = ""
    }

    private func setGlossary(_ value: [SpeechTranslationTerm]) {
        glossary = value
        settings.speechTranslationTerms = value
    }

    private func pairRow(
        @ViewBuilder source: () -> some View, @ViewBuilder target: () -> some View, @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: DS.Space.sm) {
            source().frame(maxWidth: .infinity, alignment: .leading)
            target().frame(maxWidth: .infinity, alignment: .leading)
            trailing().frame(width: DS.Size.trash)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }

    private func group(_ title: LocalizedStringKey, first: Bool = false) -> some View {
        Text(title)
            .font(DS.Font.groupHeading)
            .foregroundStyle(DS.Palette.text)
            .padding(.top, first ? 0 : 22)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(DS.Font.meta)
            .foregroundStyle(DS.Palette.secondary)
            .padding(.top, DS.Space.xs)
    }
}
