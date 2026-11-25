import Foundation

/// Why a word or a replacement is on the Vocabulary page. Spec: docs/design/papuga-embed/changes/03-dictionary.md.
enum VocabularySignal: String, Codable, Equatable {
    /// Typed and left alone by the layout fixer (S2).
    case typed
    /// The user undid its layout fix (S1).
    case undo
    /// Switched to the other layout by hand with Convert (S4).
    case manualSwitch
}

struct VocabularyEvidence: Codable, Equatable {
    var signal: VocabularySignal
    var count: Int
    var days: Int
}

/// What the side file says about a word on the list. A word with no entry was typed into the add field.
struct VocabularyWordMeta: Codable, Equatable {
    enum Source: String, Codable { case fromTyping, addedAutomatically }
    var source: Source
    var addedAt: Date
    var evidence: VocabularyEvidence?
}

struct VocabularyPendingItem: Codable, Equatable, Identifiable {
    enum Kind: Codable, Equatable {
        case word(String)
        /// Scope is always typing: the only replacement signal built is Convert (S4).
        case replacement(from: String, to: String)
    }

    var id = UUID()
    var kind: Kind
    var evidence: VocabularyEvidence
    var proposedAt: Date

    /// The key an "Ignore" remembers, in Papuga's shape.
    var ignoreKey: String {
        switch kind {
        case let .word(word): VocabularyRules.wordKey(word)
        case let .replacement(from, to): VocabularyRules.ruleKey(from: from, to: to)
        }
    }
}

/// `vocabulary_extras.json`: everything `speechVocabularyTerms` (a string array) cannot hold.
struct VocabularyExtras: Codable, Equatable {
    var version = 1
    /// Key: the term, lowercased.
    var meta: [String: VocabularyWordMeta] = [:]
    var pending: [VocabularyPendingItem] = []
    /// Keys of items answered with "Ignore".
    var ignored: [String] = []
    /// Lowercased words deleted after an automatic add. Never added or proposed again.
    var removedAuto: [String] = []
}

/// One counter in `vocabulary_evidence.json`.
struct VocabularyCounter: Codable, Equatable {
    var spelling: String
    /// Only for `manualSwitch`: what the token became.
    var target: String?
    var count = 0
    /// Calendar days as "yyyy-MM-dd".
    var days: [String] = []
    var lastSeen: Date

    var evidence: (count: Int, days: Int) { (count, days.count) }
}

/// The thresholds and the decision. Pure, so tests need no files and no speller.
enum VocabularyRules {
    /// Starting values (spec 4.1, 2.3, 2.5). Tune on real typing history before release.
    static let strongCount = 3
    static let strongDays = 2
    static let autoAddCeiling = 250
    static let evidenceMaxAgeDays = 30
    static let evidenceMaxTokens = 2000

    enum Decision: Equatable {
        case none
        case addAutomatically(VocabularyEvidence)
        case propose(VocabularyEvidence)
    }

    static func wordKey(_ word: String) -> String { "allowlist:\(word.lowercased())" }
    static func ruleKey(from: String, to: String) -> String { "rule:\(from.lowercased())→\(to.lowercased())" }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Adds one sighting.
    static func count(_ counter: inout VocabularyCounter, spelling: String, at date: Date) {
        counter.count += 1
        counter.spelling = spelling
        counter.lastSeen = date
        let day = dayString(date)
        if !counter.days.contains(day) { counter.days.append(day) }
    }

    /// Drops counters not seen for 30 days, then the oldest above 2000.
    static func pruned(_ counters: [String: VocabularyCounter], now: Date) -> [String: VocabularyCounter] {
        let cutoff = now.addingTimeInterval(-Double(evidenceMaxAgeDays) * 86400)
        var kept = counters.filter { $0.value.lastSeen >= cutoff }
        if kept.count > evidenceMaxTokens {
            let drop = kept.sorted { $0.value.lastSeen < $1.value.lastSeen }.prefix(kept.count - evidenceMaxTokens)
            for (key, _) in drop { kept[key] = nil }
        }
        return kept
    }

    /// The word decision (spec 4). `isKnown`: the system speller knows it in one of the user's languages.
    static func decideWord(
        _ word: String, signal: VocabularySignal, counter: VocabularyCounter,
        terms: [String], extras: VocabularyExtras, isKnown: Bool
    ) -> Decision {
        let key = word.lowercased()
        guard !isKnown,
              !terms.contains(where: { $0.lowercased() == key }),
              !extras.removedAuto.contains(key),
              !extras.ignored.contains(wordKey(word)),
              !extras.pending.contains(where: { $0.kind == .word(word) || $0.ignoreKey == wordKey(word) })
        else { return .none }
        let (count, days) = counter.evidence
        guard count >= strongCount else { return .none }
        let evidence = VocabularyEvidence(signal: signal, count: count, days: days)
        if days >= strongDays, terms.count < autoAddCeiling { return .addAutomatically(evidence) }
        return .propose(evidence)
    }

    /// Replacements always wait for a click.
    static func decideReplacement(
        from: String, to: String, counter: VocabularyCounter, existingSources: [String], extras: VocabularyExtras
    ) -> Decision {
        let key = ruleKey(from: from, to: to)
        guard counter.count >= strongCount,
              !extras.ignored.contains(key),
              !existingSources.contains(where: { $0.lowercased() == from.lowercased() }),
              !extras.pending.contains(where: { $0.ignoreKey == key })
        else { return .none }
        return .propose(VocabularyEvidence(signal: .manualSwitch, count: counter.count, days: counter.days.count))
    }
}

/// One row of the typing log, reduced to what a review needs. `kind` is hint, replaced, kept or undone.
struct TypingEvent: Equatable {
    var at: Date
    var kind: String
    var from: String
    var to: String
    var origin: String
    var app: String?
    var truncated: Bool
}

/// One typed text and what it became, counted across the log.
struct TypingPair: Equatable {
    var from: String
    var to: String
    var origin: String
    var replacements: Int
    var hints: Int
    var kept: Int
    var undos: Int
    var days: Int
    var last: Date
    var apps: [String]
    var truncated: Bool
    /// rule, vocabulary, leave or saved. A starting label for a person or an agent.
    var suggestion: String
    /// The word to add when `suggestion` is vocabulary. Empty otherwise.
    var term: String
}

/// Collapses the typing log into pairs and a starting label for each.
/// A label needs the same bar as an automatic vocabulary word: 3 times on 2 days.
/// A word the system flags is a vocabulary word only when the person's own notes already use it.
enum TypingReview {
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func pairs(
        from events: [TypingEvent],
        context: [String] = [],
        savedTerms: [String] = [],
        savedRules: [String] = [],
        calendar: Calendar = .current
    ) -> [TypingPair] {
        struct Bucket {
            var from: String
            var to: String
            var origins: [String: Int] = [:]
            var replacements = 0
            var hints = 0
            var kept = 0
            var undos = 0
            var days = Set<Date>()
            var last: Date
            var apps = Set<String>()
            var truncated = false
        }

        var buckets: [String: Bucket] = [:]
        for event in events {
            let key = event.from.lowercased() + "\u{1F}" + event.to.lowercased()
            var bucket = buckets[key] ?? Bucket(from: event.from, to: event.to, last: event.at)
            if event.at >= bucket.last {
                bucket.last = event.at
                bucket.from = event.from
                bucket.to = event.to
            }
            bucket.days.insert(calendar.startOfDay(for: event.at))
            if event.truncated { bucket.truncated = true }
            if let app = event.app, !app.isEmpty { bucket.apps.insert(app) }
            if event.origin != "unknown" { bucket.origins[event.origin, default: 0] += 1 }
            switch event.kind {
            case "replaced": bucket.replacements += 1
            case "hint": bucket.hints += 1
            case "kept": bucket.kept += 1
            case "undone": bucket.undos += 1
            default: break
            }
            buckets[key] = bucket
        }

        let terms = Set(savedTerms.map { $0.lowercased() })
        let rules = Set(savedRules.map { $0.lowercased() })
        return buckets.values.map { bucket in
            let origin = bucket.origins.max { $0.value < $1.value }?.key ?? "unknown"
            let (suggestion, term) = label(
                from: bucket.from, to: bucket.to, origin: origin,
                replacements: bucket.replacements, kept: bucket.kept, undos: bucket.undos, days: bucket.days.count,
                truncated: bucket.truncated, context: context, terms: terms, rules: rules
            )
            return TypingPair(
                from: bucket.from, to: bucket.to, origin: origin,
                replacements: bucket.replacements, hints: bucket.hints, kept: bucket.kept, undos: bucket.undos,
                days: bucket.days.count, last: bucket.last, apps: bucket.apps.sorted(),
                truncated: bucket.truncated, suggestion: suggestion, term: term
            )
        }
        .sorted { $0.last > $1.last }
    }

    /// True when `term` is a whole word inside something the person already wrote: a project, a name, a tag.
    static func mentions(_ term: String, in context: [String]) -> Bool {
        let needle = term.lowercased()
        guard needle.count >= 2 else { return false }
        return context.contains { blob in
            blob.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { String($0) == needle }
        }
    }

    private static func label(
        from: String, to: String, origin: String,
        replacements: Int, kept: Int, undos: Int, days: Int,
        truncated: Bool, context: [String], terms: Set<String>, rules: Set<String>
    ) -> (String, String) {
        if truncated { return ("leave", "") }
        let repeated = days >= VocabularyRules.strongDays
        if undos >= VocabularyRules.strongCount, repeated, undos > replacements, origin != "layout",
           mentions(from, in: context) {
            return terms.contains(from.lowercased()) ? ("saved", "") : ("vocabulary", from)
        }
        if replacements >= VocabularyRules.strongCount, repeated, undos == 0 {
            if rules.contains(from.lowercased()) { return ("saved", "") }
            if origin == "layout" { return ("rule", "") }
            if origin == "spelling" {
                if mentions(to, in: context) {
                    return terms.contains(to.lowercased()) ? ("saved", "") : ("vocabulary", to)
                }
                if mentions(from, in: context) {
                    return terms.contains(from.lowercased()) ? ("saved", "") : ("vocabulary", from)
                }
                return ("rule", "")
            }
        }
        if kept >= VocabularyRules.strongCount, repeated, mentions(from, in: context) {
            return terms.contains(from.lowercased()) ? ("saved", "") : ("vocabulary", from)
        }
        return ("leave", "")
    }
}
