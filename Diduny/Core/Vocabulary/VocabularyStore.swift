import AppKit
import Observation
import PapugaKit

/// Words learned from typing for "Vocabulary & context". The words themselves stay in `speechVocabularyTerms`
/// and accepted replacements in `typingCustomReplaceRules`; this store keeps what those cannot hold
/// (`vocabulary_extras.json`) and the counters for words not on the list yet (`vocabulary_evidence.json`).
/// Nothing here is written to the macOS spelling dictionary. Neither file leaves the Mac.
@MainActor
@Observable
final class VocabularyStore {
    static let shared = VocabularyStore()

    private(set) var extras = VocabularyExtras()
    /// Changes whenever the word list or a rule list changed here, so the page can reload.
    private(set) var revision = 0

    @ObservationIgnored private var counters: [String: VocabularyCounter] = [:]
    @ObservationIgnored private let settings: SettingsStorage
    @ObservationIgnored private let extrasURL: URL
    @ObservationIgnored private let evidenceURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isKnownWord: (String, String?) -> Bool
    @ObservationIgnored private let isPrivateField: () -> Bool

    init(
        settings: SettingsStorage = .shared,
        directory: URL = RecordingsLibraryStorage.defaultAppDirectory,
        now: @escaping () -> Date = Date.init,
        isKnownWord: @escaping (String, String?) -> Bool = VocabularyStore.systemSpellerKnows,
        isPrivateField: @escaping () -> Bool = { TypingEngine.focusedFieldIsPrivate() }
    ) {
        self.settings = settings
        self.now = now
        self.isKnownWord = isKnownWord
        self.isPrivateField = isPrivateField
        extrasURL = directory.appendingPathComponent("vocabulary_extras.json")
        evidenceURL = directory.appendingPathComponent("vocabulary_evidence.json")
        if let data = try? Data(contentsOf: extrasURL), let loaded = try? JSONDecoder().decode(VocabularyExtras.self, from: data) {
            extras = loaded
        }
        // The word list is the truth; the side file only describes it.
        let keys = Set(settings.speechVocabularyTerms.map { $0.lowercased() })
        extras.meta = extras.meta.filter { keys.contains($0.key) }
        if let data = try? Data(contentsOf: evidenceURL),
           let loaded = try? JSONDecoder().decode([String: VocabularyCounter].self, from: data) {
            counters = VocabularyRules.pruned(loaded, now: now())
        }
    }

    var pendingCount: Int { extras.pending.count }

    /// The length of the word list. Reads `revision`, so a view showing it follows adds made here.
    var termCount: Int {
        _ = revision
        return settings.speechVocabularyTerms.count
    }

    func meta(for term: String) -> VocabularyWordMeta? { extras.meta[term.lowercased()] }

    // MARK: Signals

    /// Nothing is learned while the switch is off or the focused field is private (spec 4.4, 5.5).
    private var mayLearn: Bool {
        settings.typingLearnVocabulary && !isPrivateField()
    }

    func observe(_ observation: TypingWordObservation) {
        guard mayLearn else { return }
        switch observation {
        case let .typed(word, language):
            learnWord(word, signal: .typed, language: language)
        case let .undone(original, replacement):
            // Never when the fix produced a real word: the user may simply have changed their mind.
            guard !isKnownWord(replacement, nil) else { return }
            learnWord(original, signal: .undo, language: nil)
        }
    }

    /// Convert retyped a single token in the other layout (S4). Three times gives a waiting replacement.
    func observeManualSwitch(from: String, to: String) {
        let from = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !from.contains(where: \.isWhitespace), !to.contains(where: \.isWhitespace),
              TypingEngine.isVocabularyCandidate(to), mayLearn else { return }
        let key = "switch:" + VocabularyRules.ruleKey(from: from, to: to)
        var counter = counters[key] ?? VocabularyCounter(spelling: from, target: to, lastSeen: now())
        VocabularyRules.count(&counter, spelling: from, at: now())
        counters[key] = counter
        let decision = VocabularyRules.decideReplacement(
            from: from, to: to, counter: counter,
            existingSources: settings.typingCustomReplaceRules.map(\.source), extras: extras
        )
        if case let .propose(evidence) = decision {
            extras.pending.insert(.init(kind: .replacement(from: from, to: to), evidence: evidence, proposedAt: now()), at: 0)
            saveExtras()
        }
        saveEvidence()
    }

    private func learnWord(_ raw: String, signal: VocabularySignal, language: String?) {
        guard TypingEngine.isVocabularyCandidate(raw) else { return }
        let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        let key = "\(signal.rawValue):\(word.lowercased())"
        var counter = counters[key] ?? VocabularyCounter(spelling: word, lastSeen: now())
        VocabularyRules.count(&counter, spelling: word, at: now())
        counters[key] = counter
        // Ask the speller only once the count could matter.
        let isKnown = counter.count >= VocabularyRules.strongCount && isKnownWord(word, language)
        let terms = settings.speechVocabularyTerms
        switch VocabularyRules.decideWord(word, signal: signal, counter: counter, terms: terms, extras: extras, isKnown: isKnown) {
        case let .addAutomatically(evidence):
            settings.speechVocabularyTerms = terms + [word]
            extras.meta[word.lowercased()] = .init(source: .addedAutomatically, addedAt: now(), evidence: evidence)
            counters[key] = nil
            changed()
        case let .propose(evidence):
            extras.pending.insert(.init(kind: .word(word), evidence: evidence, proposedAt: now()), at: 0)
            changed()
        case .none:
            break
        }
        saveEvidence()
    }

    // MARK: The page

    func accept(_ item: VocabularyPendingItem) {
        switch item.kind {
        case let .word(word):
            var terms = settings.speechVocabularyTerms
            guard terms.count < SpeechUserContext.termsLimit else { return }
            if !terms.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                terms.append(word)
                settings.speechVocabularyTerms = terms
            }
            extras.meta[word.lowercased()] = .init(source: .fromTyping, addedAt: now(), evidence: nil)
        case let .replacement(from, to):
            settings.typingCustomReplaceRules.insert(
                CustomAutoReplaceRule(source: from, target: to, createdAt: now(), createdFromRecommendation: true), at: 0
            )
        }
        extras.pending.removeAll { $0.id == item.id }
        changed()
    }

    /// A word an agent accepted. Same list as the Add field on the page.
    func acceptWord(_ raw: String) -> (ok: Bool, message: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return (false, "Give a word.") }
        guard TypingEngine.isVocabularyCandidate(word) else {
            return (false, "That does not look like a word Diduny can keep.")
        }
        let terms = settings.speechVocabularyTerms
        if terms.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            return (true, "\"\(word)\" is already in the vocabulary.")
        }
        guard terms.count < SpeechUserContext.termsLimit else {
            return (false, "The vocabulary list is full (\(SpeechUserContext.termsLimit) words).")
        }
        settings.speechVocabularyTerms = terms + [word]
        extras.meta[word.lowercased()] = .init(source: .fromTyping, addedAt: now(), evidence: nil)
        extras.pending.removeAll {
            if case let .word(pending) = $0.kind { return pending.caseInsensitiveCompare(word) == .orderedSame }
            return false
        }
        changed()
        return (true, "Added \"\(word)\" to the vocabulary.")
    }

    /// A replacement an agent accepted. An existing rule for the same typed text is left alone.
    func acceptReplacement(from rawFrom: String, to rawTo: String) -> (ok: Bool, message: String) {
        let from = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = rawTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return (false, "Give the typed text and what it should become.") }
        guard from.caseInsensitiveCompare(to) != .orderedSame else { return (false, "The two sides are the same.") }
        if settings.typingCustomReplaceRules.contains(where: { $0.source.caseInsensitiveCompare(from) == .orderedSame }) {
            return (true, "A replacement for \"\(from)\" already exists.")
        }
        settings.typingCustomReplaceRules.insert(CustomAutoReplaceRule(source: from, target: to, createdAt: now()), at: 0)
        extras.pending.removeAll {
            if case let .replacement(pendingFrom, _) = $0.kind { return pendingFrom.caseInsensitiveCompare(from) == .orderedSame }
            return false
        }
        changed()
        return (true, "Saved the replacement \"\(from)\" → \"\(to)\".")
    }

    /// A rule made from a row of Decisions. An existing rule for the same word is left alone.
    func addReplacement(from: String, to: String) {
        guard !settings.typingCustomReplaceRules.contains(where: { $0.source.caseInsensitiveCompare(from) == .orderedSame }) else { return }
        settings.typingCustomReplaceRules.insert(CustomAutoReplaceRule(source: from, target: to, createdAt: now()), at: 0)
        changed()
    }

    func ignore(_ item: VocabularyPendingItem) {
        extras.pending.removeAll { $0.id == item.id }
        if !extras.ignored.contains(item.ignoreKey) { extras.ignored.append(item.ignoreKey) }
        changed()
    }

    /// The page deleted a word. One added automatically is never added again.
    func wordDeleted(_ term: String) {
        let key = term.lowercased()
        if extras.meta.removeValue(forKey: key)?.source == .addedAutomatically, !extras.removedAuto.contains(key) {
            extras.removedAuto.append(key)
        }
        changed()
    }

    func deleteReplacement(_ rule: CustomAutoReplaceRule) {
        settings.typingCustomReplaceRules.removeAll { $0.id == rule.id }
        changed()
    }

    /// "Add words I keep typing to Vocabulary" was turned off: every counter goes, with its file.
    func clearTypedEvidence() {
        counters = [:]
        saveEvidence()
    }

    // MARK: Files

    private func changed() {
        revision += 1
        saveExtras()
    }

    private func saveExtras() {
        write(extras, to: extrasURL)
    }

    private func saveEvidence() {
        counters = VocabularyRules.pruned(counters, now: now())
        if counters.isEmpty {
            try? FileManager.default.removeItem(at: evidenceURL)
        } else {
            write(counters, to: evidenceURL)
        }
    }

    private func write(_ value: some Encodable, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Log.app.error("[Vocabulary] could not save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// True when the system speller knows the word in English, Ukrainian or the language it was typed in.
    static func systemSpellerKnows(_ word: String, language: String?) -> Bool {
        let checker = NSSpellChecker.shared
        // A language the speller does not have would report every word as correct.
        let languages = Set(["en", "uk"] + [language].compactMap { $0 }).compactMap { code in
            checker.availableLanguages.first { $0 == code || $0.hasPrefix(code + "_") }
        }
        return languages.contains { language in
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}
