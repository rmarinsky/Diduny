import Foundation

/// PapugaCore holds only the pure members of `AutoFixDecision` that the core
/// layer itself calls. They are copied verbatim from Papuga 1.11.0
/// (`Core/AutoFixDecision.swift`). The engine layer adds the remaining members
/// in an extension; it must not declare these again.
enum AutoFixDecision {
    static func shouldSkipWord(_ word: String, minLength: Int = 2) -> SkipReason? {
        if word.count < minLength { return .tooShort }
        // `.` and `/` are NOT blanket-forbidden: on Ukrainian-PC `.` is `ю`, so a
        // word like `.hsq` typed in EN actually maps to `юрій`. Only skip when
        // the token clearly looks URL/email-like.
        if ProtectedLexiconMatcher.isEmailLike(word) { return .containsForbiddenChars }
        if ProtectedLexiconMatcher.isURLLike(word) { return .containsForbiddenChars }
        if ProtectedLexiconMatcher.isDomainLike(word) { return .containsForbiddenChars }
        if word.first == "#" || word.first == "$" { return .containsForbiddenChars }
        for ch in word where ch.isNumber { return .containsDigits }
        return nil
    }

    static func shouldReplace(
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double
    ) -> Bool {
        return scoreCandidate - scoreOriginal >= threshold
    }

    enum SkipReason: String {
        case tooShort
        case containsDigits
        case containsForbiddenChars
    }

    static func isCrossScriptConversion(original: String, candidate: String) -> Bool {
        let originalLatin = containsLatinLetter(original)
        let originalCyrillic = containsCyrillicLetter(original)
        let candidateLatin = containsLatinLetter(candidate)
        let candidateCyrillic = containsCyrillicLetter(candidate)

        return (originalLatin && candidateCyrillic && !candidateLatin)
            || (originalCyrillic && candidateLatin && !candidateCyrillic)
    }

    static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
    }

    static func containsCyrillicLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0400...0x04FF).contains(Int(scalar.value))
        }
    }

    static func spellingConfidence(
        original: String,
        suggestion: String,
        editDistance: Int
    ) -> Double {
        let longestLength = max(original.count, suggestion.count)
        guard longestLength > 0 else { return 0 }
        let similarity = 1 - Double(max(0, editDistance)) / Double(longestLength)
        return min(1, max(0, similarity))
    }

    static func spellingEditDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var distance = Array(
            repeating: Array(repeating: 0, count: b.count + 1),
            count: a.count + 1
        )

        for i in 0...a.count {
            distance[i][0] = i
        }
        for j in 0...b.count {
            distance[0][j] = j
        }

        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                distance[i][j] = min(
                    distance[i - 1][j] + 1,
                    distance[i][j - 1] + 1,
                    distance[i - 1][j - 1] + cost
                )

                if i > 1,
                   j > 1,
                   a[i - 1] == b[j - 2],
                   a[i - 2] == b[j - 1] {
                    distance[i][j] = min(distance[i][j], distance[i - 2][j - 2] + 1)
                }
            }
        }

        return distance[a.count][b.count]
    }

    static func isInAllowlist(_ word: String, allowlist: [String]) -> Bool {
        let normalized = BufferedToken.normalizedCore(from: word).lowercased()
        guard !normalized.isEmpty else { return false }
        return allowlist.contains {
            BufferedToken.normalizedCore(from: $0).lowercased() == normalized
        }
    }
}
