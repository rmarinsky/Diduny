import Foundation

/// Word-level diff of a transcript against a reference. Nothing is normalised:
/// case, punctuation, apostrophes, fillers and number formats all count (spec OQ-8).
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
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func compare(_ hypothesis: String, reference: String) -> Result {
        let ref = words(reference), hyp = words(hypothesis)
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
                ops.append(ref[i - 1] == hyp[j - 1] ? .equal(hyp[j - 1]) : .substituted(word: hyp[j - 1], reference: ref[i - 1]))
                i -= 1; j -= 1
            } else if i > 0, dist[i][j] == dist[i - 1][j] + 1 {
                ops.append(.missing(ref[i - 1]))
                i -= 1
            } else {
                ops.append(.inserted(hyp[j - 1]))
                j -= 1
            }
        }
        let errors = dist[n][m]
        return Result(ops: ops.reversed(), rate: n == 0 ? (m == 0 ? 0 : 1) : Double(errors) / Double(n))
    }
}
