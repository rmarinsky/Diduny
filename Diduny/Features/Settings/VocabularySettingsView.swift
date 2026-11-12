import SwiftUI

/// Settings > Vocabulary & context: what Diduny Cloud receives as `user_context` (see `SpeechUserContext`).
struct VocabularySettingsView: View {
    var settings: SettingsStorage = .shared

    @State private var terms: [String] = []
    @State private var newTerm = ""
    @State private var domain = ""
    @State private var glossary: [SpeechTranslationTerm] = []
    @State private var newSource = ""
    @State private var newTarget = ""
    @State private var usesCalendar = true

    var body: some View {
        PageScaffold(
            title: "Vocabulary & context",
            subtitle: "Diduny Cloud receives these words and description at the start of each recording to recognize names and terms better. Applies only to Diduny Cloud."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                group("Words and names", first: true)
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
                                Text(verbatim: term).font(DS.Font.body)
                                Spacer()
                                TrashButton(accessibilityLabel: "Delete \(term)") { setTerms(terms.filter { $0 != term }) }
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
        .onAppear {
            terms = settings.speechVocabularyTerms
            domain = settings.speechDomain
            glossary = settings.speechTranslationTerms
            usesCalendar = settings.speechUsesCalendarContext
        }
        .onChange(of: usesCalendar) { _, new in settings.speechUsesCalendarContext = new }
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
        guard let source = newSource.nilIfBlank, let target = newTarget.nilIfBlank,
              glossary.count < SpeechUserContext.translationTermsLimit else { return }
        setGlossary(glossary + [SpeechTranslationTerm(source: source, target: target)])
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
