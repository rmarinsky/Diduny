import PapugaKit
import SwiftUI

/// Vocabulary > Decisions: the typing engine's log (layout fixes, spelling fixes, rules, undos), newest first.
struct VocabularyDecisionsView: View {
    @State private var model: VocabularyDecisionsModel
    @State private var isAskingToClear = false

    init(model: VocabularyDecisionsModel? = nil) {
        _model = State(initialValue: model ?? VocabularyDecisionsModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            summary
            Card(padding: 0) {
                VStack(spacing: 0) {
                    let rows = Array(model.visible.prefix(200))
                    if rows.isEmpty {
                        Text("No decisions yet.")
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                            .accessibilityIdentifier("vocabulary.decisions.empty")
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, decision in
                        if index > 0 { RowSeparator() }
                        row(decision)
                    }
                }
            }
            .padding(.top, DS.Space.md)
            .accessibilityIdentifier("vocabulary.decisions.list")
            Text("Obvious checks, like a word that is already right, are counted without saving any text.")
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.secondary)
                .padding(.top, DS.Space.xs)

            Text("Decisions log")
                .font(DS.Font.groupHeading)
                .foregroundStyle(DS.Palette.text)
                .padding(.top, 22)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingsLineRow(title: "Keep the log for", kind: .popUp) {
                        Picker("Keep the log for", selection: Binding(
                            get: { model.retention }, set: { model.retention = $0 }
                        )) {
                            ForEach(ReplacementHistoryRetention.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        .accessibilityIdentifier("vocabulary.decisions.retention")
                    }
                    // The question is in the row itself, as for "Clear the clipboard history".
                    SettingsLineRow(title: "Clear decisions", kind: .button, showsHairline: false) {
                        if isAskingToClear {
                            Button(role: .destructive) {
                                model.clear()
                                isAskingToClear = false
                            } label: { Text("Clear everything").foregroundStyle(DS.Palette.no) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("vocabulary.decisions.clear.confirm")
                            Button("Keep") { isAskingToClear = false }
                                .buttonStyle(.bordered)
                        } else {
                            Button(role: .destructive) { isAskingToClear = true } label: {
                                Text("Clear").foregroundStyle(DS.Palette.no)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.decisions.isEmpty)
                            .accessibilityIdentifier("vocabulary.decisions.clear")
                        }
                    }
                }
                .padding(.horizontal, DS.Space.md)
            }
        }
        .onAppear { model.reload() }
    }

    // MARK: - Filters and cards

    private var controls: some View {
        HStack(spacing: DS.Space.sm) {
            Picker("Period", selection: $model.period) {
                ForEach(VocabularyDecisionsModel.Period.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("vocabulary.decisions.period")
            TextField("Search", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("vocabulary.decisions.search")
            Picker("Show", selection: $model.kindFilter) {
                ForEach(VocabularyDecisionsModel.KindFilter.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("vocabulary.decisions.kind")
        }
    }

    private var summary: some View {
        HStack(spacing: DS.Space.sm) {
            card("Signals", "\(model.counts.signals)")
            card("Replaced", "\(model.replacedPercent)%")
            card("Hints", "\(model.hintsPercent)%")
            card("Undone by you", "\(model.counts.undone)")
        }
        .padding(.top, DS.Space.md)
        .accessibilityIdentifier("vocabulary.decisions.summary")
    }

    private func card(_ title: LocalizedStringKey, _ value: String) -> some View {
        Card(padding: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
                Text(verbatim: value).font(DS.Font.settingsTitle).foregroundStyle(DS.Palette.text)
            }
        }
    }

    // MARK: - Rows

    private func row(_ decision: TypingDecision) -> some View {
        HStack(spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(decision.original) → \(decision.converted)")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.text)
                Text(verbatim: Self.detail(decision))
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
            }
            Spacer(minLength: DS.Space.sm)
            Text(Self.label(decision))
                .font(DS.Font.captionStrong)
                .foregroundStyle(DS.Palette.secondary)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 2)
                .background(DS.Palette.chip, in: Capsule())
            if let confidence = decision.confidence {
                Text(verbatim: "\(Int((confidence * 100).rounded()))%")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            if model.canMakeRule(decision) {
                Button("Make a rule") { model.makeRule(decision) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("vocabulary.decisions.makeRule")
            }
            if model.canNeverFix(decision) {
                Button("Never fix") { model.neverFix(decision) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("vocabulary.decisions.neverFix")
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }

    /// "Notes, 14:32": the app when it is installed, then the time (with the date after today).
    private static func detail(_ decision: TypingDecision) -> String {
        let when = Calendar.current.isDateInToday(decision.timestamp)
            ? decision.timestamp.formatted(date: .omitted, time: .shortened)
            : decision.timestamp.formatted(date: .abbreviated, time: .shortened)
        guard let bundleID = decision.bundleID, let app = TypingSettingsModel.installedAppName(bundleID) else { return when }
        return "\(app), \(when)"
    }

    // MARK: - English labels for the engine's kinds

    static func label(_ decision: TypingDecision) -> LocalizedStringKey {
        switch (decision.kind, decision.origin) {
        case (.undone, _): "Undone"
        case (.hint, _): "Hint"
        case (.replaced, .rule?): "Rule"
        case (.replaced, .spelling?): "Spelling fix"
        case (.replaced, _): "Layout fix"
        }
    }

    static func title(_ period: VocabularyDecisionsModel.Period) -> LocalizedStringKey {
        switch period {
        case .today: "Today"
        case .week: "Week"
        case .month: "Month"
        case .allTime: "All time"
        }
    }

    static func title(_ kind: VocabularyDecisionsModel.KindFilter) -> LocalizedStringKey {
        switch kind {
        case .all: "All"
        case .hints: "Hints"
        case .replacements: "Replacements"
        case .undone: "Undone"
        }
    }

    static func title(_ retention: ReplacementHistoryRetention) -> LocalizedStringKey {
        switch retention {
        case .oneWeek: "1 week"
        case .oneMonth: "1 month"
        case .threeMonths: "3 months"
        case .forever: "Forever"
        }
    }
}
