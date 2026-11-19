import Foundation
import Observation
import PapugaKit

/// Vocabulary > Decisions: what the typing engine did and proposed, read from its log on disk (the engine
/// need not be running). Everything shown stays on the Mac.
@MainActor
@Observable
final class VocabularyDecisionsModel {
    enum Period: CaseIterable { case today, week, month, allTime }
    enum KindFilter: CaseIterable { case all, hints, replacements, undone }

    var period: Period = .month
    var kindFilter: KindFilter = .all
    var search = ""
    private(set) var decisions: [TypingDecision] = []
    /// Bumped by an action, so a row re-reads whether it still offers it.
    private(set) var revision = 0

    @ObservationIgnored private let settings: SettingsStorage
    @ObservationIgnored private let store: VocabularyStore
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar

    init(
        settings: SettingsStorage = .shared,
        store: VocabularyStore = .shared,
        directory: URL = RecordingsLibraryStorage.defaultAppDirectory.appendingPathComponent("Typing"),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.settings = settings
        self.store = store
        self.directory = directory
        self.now = now
        self.calendar = calendar
        reload()
    }

    func reload() {
        decisions = TypingDecisionLog.load(directory: directory)
    }

    // MARK: - What the page shows

    /// The decisions of the chosen period, before the kind filter and the search; the cards count these.
    var inPeriod: [TypingDecision] {
        guard let start = periodStart else { return decisions }
        return decisions.filter { $0.timestamp >= start }
    }

    var counts: TypingDecisionCounts { TypingDecisionCounts(inPeriod) }

    /// Whole percent of the period's decisions; 0 with none.
    var replacedPercent: Int { percent(counts.replaced) }
    var hintsPercent: Int { percent(counts.hints) }

    var visible: [TypingDecision] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return inPeriod.filter { decision in
            switch kindFilter {
            case .all: true
            case .hints: decision.kind == .hint
            case .replacements: decision.kind == .replaced
            case .undone: decision.kind == .undone
            }
        }
        .filter { query.isEmpty || $0.original.localizedCaseInsensitiveContains(query) || $0.converted.localizedCaseInsensitiveContains(query) }
    }

    private var periodStart: Date? {
        switch period {
        case .today: calendar.startOfDay(for: now())
        case .week: calendar.date(byAdding: .day, value: -7, to: now())
        case .month: calendar.date(byAdding: .month, value: -1, to: now())
        case .allTime: nil
        }
    }

    private func percent(_ part: Int) -> Int {
        let total = counts.signals
        return total == 0 ? 0 : Int((Double(part) / Double(total) * 100).rounded())
    }

    // MARK: - Actions (each uses what Typing and Vocabulary already have)

    /// A rule shows for a layout or spelling fix that has none yet; a decision made by a rule already is one.
    func canMakeRule(_ decision: TypingDecision) -> Bool {
        _ = revision
        guard decision.kind != .undone, decision.origin != .rule else { return false }
        return !settings.typingCustomReplaceRules.contains { $0.source.caseInsensitiveCompare(decision.original) == .orderedSame }
    }

    func makeRule(_ decision: TypingDecision) {
        guard canMakeRule(decision) else { return }
        store.addReplacement(from: decision.original, to: decision.converted)
        revision += 1
    }

    func canNeverFix(_ decision: TypingDecision) -> Bool {
        _ = revision
        return !settings.typingNeverFixWords.contains { $0.caseInsensitiveCompare(decision.original) == .orderedSame }
    }

    func neverFix(_ decision: TypingDecision) {
        settings.addTypingNeverFixWord(decision.original)
        revision += 1
    }

    func clear() {
        TypingDecisionLog.clear(directory: directory)
        reload()
    }

    var retention: ReplacementHistoryRetention {
        get { settings.typingHistoryRetention }
        set { settings.typingHistoryRetention = newValue }
    }
}
