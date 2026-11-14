import Foundation

struct ProtectedLexiconPredictionAdjustment: Equatable {
    let originalMatch: ProtectedLexiconMatch?
    let candidateMatch: ProtectedLexiconMatch?
    let adjustedCandidateScore: Double
    let adjustedThreshold: Double
    let shouldSuppress: Bool
    let reasons: [String]

    var hasCandidateBoost: Bool {
        candidateMatch?.boostsCandidate == true
    }
}

enum ProtectedLexiconPredictionScorer {
    static let defaultCandidateBoost = 0.24
    static let defaultBoostedThreshold = 0.12

    static func adjustment(
        original: String,
        candidate: String,
        scoreCandidate: Double,
        threshold: Double,
        matcher: ProtectedLexiconMatcher = ProtectedLexiconStore.shared
    ) -> ProtectedLexiconPredictionAdjustment {
        let originalMatch = matcher.match(original)
        let candidateMatch = matcher.match(candidate)
        var reasons = [String]()

        if originalMatch?.protectsSource == true {
            reasons.append("protected_source")
        }

        var adjustedScore = scoreCandidate
        var adjustedThreshold = threshold

        if let candidateMatch, candidateMatch.boostsCandidate {
            adjustedScore = min(1.0, adjustedScore + defaultCandidateBoost * candidateMatch.entry.confidence)
            adjustedThreshold = min(threshold, defaultBoostedThreshold)
            reasons.append("boosted_candidate")
        }

        if candidateMatch?.preservesCasing == true {
            reasons.append("preserve_casing")
        }

        return ProtectedLexiconPredictionAdjustment(
            originalMatch: originalMatch,
            candidateMatch: candidateMatch,
            adjustedCandidateScore: adjustedScore,
            adjustedThreshold: adjustedThreshold,
            shouldSuppress: originalMatch?.protectsSource == true,
            reasons: reasons
        )
    }

    static func grammarPromptHints(
        text: String,
        matcher: ProtectedLexiconMatcher = ProtectedLexiconStore.shared,
        limit: Int = 24
    ) -> [String] {
        let tokens = tokenize(text)
        var seen = Set<String>()
        var hints = [String]()

        for token in tokens {
            guard let match = matcher.match(token),
                  match.supportsGrammarPrediction || match.supportsSpellingPrediction else {
                continue
            }

            let canonical = match.entry.canonical
            guard seen.insert(canonical.lowercased()).inserted else { continue }
            hints.append(canonical)

            if hints.count >= limit {
                break
            }
        }

        return hints
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split { character in
            character.isWhitespace
        }.map(String.init)
    }
}
