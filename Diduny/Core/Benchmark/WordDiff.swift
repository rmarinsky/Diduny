import Foundation

/// Word-level diff of a transcript against a reference. Strict mode counts
/// everything (case, punctuation, number formats — spec OQ-8); the relaxed mode
/// compares lowercased words without surrounding punctuation, so only real word
/// differences remain. Ops always carry the original words for display.
enum WordDiff {
    enum Op: Equatable, Codable {
        case equal(String)
        /// `word` replaced the reference word `reference`.
        case substituted(word: String, reference: String)
        /// A reference word this transcript lacks.
        case missing(String)
        /// A word only this transcript has.
        case inserted(String)
    }

    struct Result: Equatable {
        let ops: [Op]
        /// Word error rate vs the reference: (substitutions + deletions + insertions) / reference words.
        let rate: Double
        /// Reference words the rate is measured against (after normalisation).
        var referenceWords = 0
        /// Errors behind `rate`: substitutions + deletions + insertions.
        var errors: Int { Int((rate * Double(referenceWords)).rounded()) }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Lowercased word with leading/trailing punctuation removed; nil when nothing is left (e.g. "—").
    static func key(_ word: String) -> String? {
        let trimmed = word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func compare(_ hypothesis: String, reference: String, strict: Bool = true) -> Result {
        let pairs: (String) -> [(word: String, key: String)] = { text in
            words(text).compactMap { word in
                strict ? (word, word) : key(word).map { (word, $0) }
            }
        }
        let refPairs = pairs(reference), hypPairs = pairs(hypothesis)
        let ref = refPairs.map(\.key), hyp = hypPairs.map(\.key)
        let n = ref.count, m = hyp.count
        var dist = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0 ... n { dist[i][0] = i }
        for j in 0 ... m { dist[0][j] = j }
        if n > 0, m > 0 {
            for i in 1 ... n {
                for j in 1 ... m {
                    let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                    dist[i][j] = min(dist[i - 1][j] + 1, dist[i][j - 1] + 1, dist[i - 1][j - 1] + cost)
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, dist[i][j] == dist[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1) {
                ops.append(ref[i - 1] == hyp[j - 1]
                    ? .equal(hypPairs[j - 1].word)
                    : .substituted(word: hypPairs[j - 1].word, reference: refPairs[i - 1].word))
                i -= 1; j -= 1
            } else if i > 0, dist[i][j] == dist[i - 1][j] + 1 {
                ops.append(.missing(refPairs[i - 1].word))
                i -= 1
            } else {
                ops.append(.inserted(hypPairs[j - 1].word))
                j -= 1
            }
        }
        let errors = dist[n][m]
        return Result(ops: ops.reversed(), rate: n == 0 ? (m == 0 ? 0 : 1) : Double(errors) / Double(n), referenceWords: n)
    }
}
