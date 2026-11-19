import AppKit
import Foundation

/// Hybrid spell-check client: the authoritative system checker, plus SymSpell
/// candidate generation, plus a **learned-known overlay**.
///
/// The system checker and learned vocabulary protect original words from false
/// positives. The frequency index is strict only for mapped layout candidates.
/// `guesses` merges fast SymSpell corrections ahead of the system's.
final class HybridSpellChecker: SpellCheckingClient {
    /// Was `static let production`, which read the Papuga settings `autoFixAllowlist` and
    /// `customAutoReplaceRules` (both default `[]`). Each call builds a new checker and
    /// starts a background index load, so the host calls it once and keeps the result.
    static func production(
        allowlist: [String] = [],
        rules: [CustomAutoReplaceRule] = []
    ) -> HybridSpellChecker {
        let known = LearnedVocabulary.knownGoodWords(allowlist: allowlist, rules: rules)
        let learnedKnown = Dictionary(grouping: known, by: { word in
            word.unicodeScalars.contains { (0x0400...0x04FF).contains(Int($0.value)) } ? "uk" : "en"
        }).mapValues(Set.init)
        let checker = HybridSpellChecker(learnedKnown: learnedKnown)
        DispatchQueue.global(qos: .utility).async {
            let base = [
                "uk": DictionaryBuilder.loadBundledBase(language: "uk"),
                "en": DictionaryBuilder.loadBundledBase(language: "en")
            ]
            let learned = DictionaryBuilder.learnedFrequencies(from: learnedKnown.flatMap { language, words in
                words.map { (token: $0, language: language) }
            })
            checker.installIndexes(DictionaryBuilder.build(base: base, learned: learned))
        }
        return checker
    }

    private let system: SpellCheckingClient
    private var indexes: [String: SymSpell]
    private let learnedKnown: [String: Set<String>]
    private let maxEditDistance: Int
    private let lock = NSLock()
    private var systemReliability: [String: Bool] = [:]

    init(
        system: SpellCheckingClient = SystemSpellCheckingClient(),
        indexes: [String: SymSpell] = [:],
        learnedKnown: [String: Set<String>] = [:],
        maxEditDistance: Int = 2
    ) {
        self.system = system
        self.indexes = indexes
        self.learnedKnown = learnedKnown.mapValues { Set($0.map(Self.vocabularyKey)) }
        self.maxEditDistance = maxEditDistance
    }

    private static func vocabularyKey(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "ʼ", with: "'")
            .replacingOccurrences(of: "’", with: "'")
    }

    func installIndexes(_ indexes: [String: SymSpell]) {
        lock.withLock { self.indexes = indexes }
    }

    /// `log10(1 + count)` for a word in the frequency list, 0 when absent.
    /// Ranking signal only — never a correctness signal.
    func logFrequency(of word: String, language: String) -> Double {
        guard let count = lock.withLock({ indexes[language]?.words[Self.vocabularyKey(word)] }),
              count > 0 else { return 0 }
        return log10(1 + Double(count))
    }

    /// Which languages currently have a frequency index installed.
    ///
    /// `production` builds its indexes on a background queue, so anything
    /// measuring guess *quality* has to wait for them rather than silently
    /// sampling the pre-load state. Correctness no longer depends on this —
    /// the index only promotes — but ranking does.
    var indexedLanguages: Set<String> {
        Set(lock.withLock { indexes.keys })
    }

    /// Explicit vocabulary evidence, independent of permissive system abbreviation checks.
    func isExplicitlyKnown(_ word: String, language: String) -> Bool {
        let key = Self.vocabularyKey(word)
        return learnedKnown[language]?.contains(key) == true
            || lock.withLock { indexes[language]?.words[key] != nil }
    }

    /// Explicit and learned vocabulary always promotes a word. A calibrated
    /// system dictionary remains authoritative for words outside that vocabulary.
    /// Some macOS environments advertise a dictionary while accepting nonsense;
    /// fail closed only when that calibration probe proves the system unreliable.
    func isMisspelled(_ word: String, language: String) -> Bool {
        let key = Self.vocabularyKey(word)
        if learnedKnown[language]?.contains(key) == true { return false }
        if lock.withLock({ indexes[language] })?.words[key] != nil { return false }
        guard Self.systemSupports(language), systemDictionaryIsReliable(language: language) else {
            return true
        }
        return system.isMisspelled(word, language: language)
    }

    /// The frequency index may only ever **promote** a word to `.correct`; it
    /// may never demote one to `.misspelled`.
    ///
    /// The index is 50k conversational surface forms per language. It is a good
    /// "this is definitely a word" signal and a hopeless "this is definitely
    /// not a word" signal: it contains no Ukrainian apostrophe forms at all
    /// (`п'ять`, `м'ясо`, `об'єкт`…) and only a fraction of an inflected
    /// language's forms. Treating absence as proof of misspelling is what made
    /// correct-but-uncommon Ukrainian unfixable.
    ///
    /// So the ordering is: learned overlay, then index overlay, then the
    /// system dictionary as the actual authority. That restores the invariant
    /// this file was written with — the index can only remove false positives,
    /// never add new ones — and makes the async `installIndexes` load
    /// behaviourally invisible rather than a silent first-run quality cliff.
    ///
    /// `.unavailable` now means "no authority can answer for this language",
    /// not "no SymSpell index" (which was always true for ru/pl/de). Asking
    /// NSSpellChecker about a language it does not support silently falls back
    /// to automatic detection and returns nonsense, so that case must stay
    /// distinguishable from a real verdict.
    func mappedSpellingStatus(_ word: String, language: String) -> MappedSpellingStatus {
        let key = Self.vocabularyKey(word)
        if learnedKnown[language]?.contains(key) == true { return .correct }
        if lock.withLock({ indexes[language] })?.words[key] != nil { return .correct }
        guard Self.systemSupports(language), systemDictionaryIsReliable(language: language) else {
            return .unavailable
        }
        return system.isMisspelled(word, language: language) ? .misspelled : .correct
    }

    private func systemDictionaryIsReliable(language: String) -> Bool {
        if let cached = lock.withLock({ systemReliability[language] }) { return cached }
        let base = String(language.prefix(while: { $0 != "_" && $0 != "-" })).lowercased()
        let calibrationToken = base == "uk" || base == "ru" ? "жцщфґк" : "qxzvjk"
        let reliable = system.isMisspelled(calibrationToken, language: language)
        lock.withLock { systemReliability[language] = reliable }
        return reliable
    }

    /// `NSSpellChecker.availableLanguages` is a stable, cheap-to-snapshot list,
    /// but it is an IPC round-trip, so take it once.
    private static let supportedSystemLanguages: Set<String> = {
        Set(NSSpellChecker.shared.availableLanguages.map { code in
            // Entries look like "uk", "en_GB", "pt_PT" — compare on the base.
            String(code.prefix(while: { $0 != "_" && $0 != "-" })).lowercased()
        })
    }()

    static func systemSupports(_ language: String) -> Bool {
        let base = String(language.prefix(while: { $0 != "_" && $0 != "-" })).lowercased()
        guard !base.isEmpty else { return false }
        return supportedSystemLanguages.contains(base)
    }

    func guesses(for word: String, language: String) -> [String] {
        rankedGuesses(for: word, language: language).map(\.term)
    }

    /// Keeps SymSpell's distance and corpus count instead of flattening to
    /// bare strings. Those two numbers are what let the ranking put `help`
    /// ahead of `halo` for `helo`; without them every same-distance guess
    /// scored identically and fell through to an alphabetical tie-break.
    ///
    /// System guesses come after SymSpell's and carry no count, so they sort
    /// below an equally-distant corpus-attested word — but they are still
    /// merged in, because the system dictionary knows inflected and apostrophe
    /// forms the 50k list does not.
    func rankedGuesses(for word: String, language: String) -> [ScoredGuess] {
        let probe = Self.vocabularyKey(word)
        var merged: [ScoredGuess] = []
        var seen = Set<String>()

        if let index = lock.withLock({ indexes[language] }) {
            for suggestion in index.lookup(probe, maxEditDistance: maxEditDistance, max: 6)
            where seen.insert(suggestion.term).inserted {
                merged.append(ScoredGuess(
                    term: suggestion.term,
                    distance: suggestion.distance,
                    count: suggestion.count
                ))
            }
        }

        let indexWords = lock.withLock { indexes[language]?.words }
        for guess in system.guesses(for: word, language: language)
        where seen.insert(Self.vocabularyKey(guess)).inserted {
            let distance = SymSpell.damerauLevenshtein(Array(probe), Array(Self.vocabularyKey(guess)))
            merged.append(ScoredGuess(
                term: guess,
                distance: distance,
                count: indexWords?[Self.vocabularyKey(guess)] ?? 0
            ))
        }
        return merged
    }
}
