import Foundation

/// Symmetric Delete spelling correction (Wolf Garbe, 2012).
///
/// Precomputes, for every dictionary word, the strings reachable by ≤ k
/// deletions (on a length-`prefixLength` prefix) and maps them back to the word.
/// A lookup deletes the *input* the same way and probes the index — so a single
/// hash lookup family covers inserts/replaces/transposes/deletes symmetrically.
/// Lookups are effectively O(1) in dictionary size and **language-independent**
/// (works on characters, not an alphabet model) — ideal for on-device uk+en.
///
/// Reference: https://github.com/wolfgarbe/SymSpell — ~33 µs/word at edit
/// distance 2, ~1000× faster than a brute-force (Norvig) generator.
final class SymSpell {
    struct Suggestion: Equatable {
        let term: String
        let distance: Int
        let count: Int
    }

    private let maxDictionaryEditDistance: Int
    private let prefixLength: Int

    private(set) var words: [String: Int] = [:]
    private var deletes: [String: [String]] = [:]
    private var maxDictionaryWordLength = 0

    init(maxDictionaryEditDistance: Int = 2, prefixLength: Int = 7) {
        precondition(prefixLength > maxDictionaryEditDistance && prefixLength > 0)
        self.maxDictionaryEditDistance = maxDictionaryEditDistance
        self.prefixLength = prefixLength
    }

    var wordCount: Int { words.count }
    var deleteEntryCount: Int { deletes.count }

    // MARK: - Build

    func createDictionaryEntry(_ key: String, count: Int) {
        guard count > 0, !key.isEmpty else { return }
        if let existing = words[key] {
            words[key] = existing &+ count
            return // deletes already generated for this key
        }
        words[key] = count
        maxDictionaryWordLength = max(maxDictionaryWordLength, key.count)

        for delete in editsPrefix(key) {
            deletes[delete, default: []].append(key)
        }
    }

    /// Bulk-load a frequency dictionary (word, count).
    func load<S: Sequence>(_ entries: S) where S.Element == (String, Int) {
        for (word, count) in entries { createDictionaryEntry(word.lowercased(), count: count) }
    }

    private func editsPrefix(_ key: String) -> Set<String> {
        var set = Set<String>()
        let chars = Array(key)
        if chars.count <= maxDictionaryEditDistance { set.insert("") }
        let prefix = chars.count > prefixLength ? String(chars.prefix(prefixLength)) : key
        set.insert(prefix)
        edits(Array(prefix), editDistance: 0, into: &set)
        return set
    }

    private func edits(_ chars: [Character], editDistance: Int, into set: inout Set<String>) {
        let nextDistance = editDistance + 1
        guard chars.count > 1 else { return }
        for i in chars.indices {
            var deleted = chars
            deleted.remove(at: i)
            let deleteStr = String(deleted)
            if set.insert(deleteStr).inserted, nextDistance < maxDictionaryEditDistance {
                edits(deleted, editDistance: nextDistance, into: &set)
            }
        }
    }

    // MARK: - Lookup

    /// Top-`max` corrections of `input` within `maxEditDistance`, ranked by edit
    /// distance then frequency.
    func lookup(_ input: String, maxEditDistance: Int? = nil, max: Int = 5) -> [Suggestion] {
        let maxDistance = min(maxEditDistance ?? maxDictionaryEditDistance, maxDictionaryEditDistance)
        let phrase = input
        let phraseChars = Array(phrase)
        let phraseLen = phraseChars.count
        guard phraseLen > 0 else { return [] }

        if phraseLen - maxDistance > maxDictionaryWordLength { return [] }

        var suggestions: [Suggestion] = []
        var consideredDeletes = Set<String>()
        var consideredSuggestions = Set<String>()
        consideredSuggestions.insert(phrase)

        // Exact match short-circuit.
        if let count = words[phrase] {
            suggestions.append(Suggestion(term: phrase, distance: 0, count: count))
        }

        let phrasePrefixLen = Swift.min(phraseLen, prefixLength)
        var candidates: [String] = [String(phraseChars.prefix(phrasePrefixLen))]
        var ci = 0

        while ci < candidates.count {
            let candidate = candidates[ci]; ci += 1
            let candidateChars = Array(candidate)
            let candidateLen = candidateChars.count
            let lengthDiff = phrasePrefixLen - candidateLen
            if lengthDiff > maxDistance { continue }

            if let dictWords = deletes[candidate] {
                for suggestion in dictWords {
                    if suggestion == phrase { continue }
                    let suggestionLen = suggestion.count
                    if abs(suggestionLen - phraseLen) > maxDistance { continue }
                    if suggestionLen < candidateLen { continue }
                    if suggestionLen == candidateLen, suggestion != candidate { continue }
                    guard consideredSuggestions.insert(suggestion).inserted else { continue }

                    let distance = Self.damerauLevenshtein(phraseChars, Array(suggestion), max: maxDistance)
                    if distance >= 0, distance <= maxDistance {
                        suggestions.append(Suggestion(term: suggestion, distance: distance, count: words[suggestion] ?? 0))
                    }
                }
            }

            // Enqueue deletes of the candidate (within the prefix window).
            if lengthDiff < maxDistance, candidateLen <= prefixLength {
                for i in candidateChars.indices {
                    var deleted = candidateChars
                    deleted.remove(at: i)
                    let deleteStr = String(deleted)
                    if consideredDeletes.insert(deleteStr).inserted {
                        candidates.append(deleteStr)
                    }
                }
            }
        }

        suggestions.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.count > rhs.count
        }
        return Array(suggestions.prefix(max))
    }

    // MARK: - Damerau-Levenshtein (optimal string alignment), bounded

    /// OSA distance; returns -1 early if it provably exceeds `max`. Uses a single
    /// flat buffer (nested Swift arrays are an allocation hotspot when this runs
    /// per candidate inside a lookup).
    static func damerauLevenshtein(_ a: [Character], _ b: [Character], max: Int = .max) -> Int {
        let n = a.count, m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        if abs(n - m) > max { return -1 }

        let width = m + 1
        var d = [Int](repeating: 0, count: (n + 1) * width)
        for i in 0...n { d[i * width] = i }
        for j in 0...m { d[j] = j }

        for i in 1...n {
            let ai = a[i - 1]
            var rowMin = Int.max
            for j in 1...m {
                let cost = ai == b[j - 1] ? 0 : 1
                var value = Swift.min(
                    d[(i - 1) * width + j] + 1,
                    d[i * width + (j - 1)] + 1,
                    d[(i - 1) * width + (j - 1)] + cost
                )
                if i > 1, j > 1, ai == b[j - 2], a[i - 2] == b[j - 1] {
                    value = Swift.min(value, d[(i - 2) * width + (j - 2)] + 1)
                }
                d[i * width + j] = value
                if value < rowMin { rowMin = value }
            }
            if rowMin > max { return -1 }
        }
        // The per-row `rowMin` prune bounds the cheapest cell in a row, not the
        // final cell, so the last cell can still exceed `max` (e.g. "abc" vs
        // "abzz" with max 1 returns 2). `lookup` re-checks, but callers that
        // trust the `>= 0` contract alone did not — callers'
        // "close fix" test counted 2-edit candidates and so kept suppressing
        // domain-vocabulary learning.
        let distance = d[n * width + m]
        return distance > max ? -1 : distance
    }
}
