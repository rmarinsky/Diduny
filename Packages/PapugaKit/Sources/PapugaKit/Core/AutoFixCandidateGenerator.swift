import Foundation

/// One transliteration candidate for a given target layout, paired with its language score.
struct AutoFixTargetCandidate: Equatable {
    let targetID: String
    let targetLang: String
    let candidate: String
    let scoreCandidate: Double
    let replacementPlan: ReplacementPlan?
    let isInterpretationAmbiguous: Bool

    init(
        targetID: String,
        targetLang: String,
        candidate: String,
        scoreCandidate: Double,
        replacementPlan: ReplacementPlan? = nil,
        isInterpretationAmbiguous: Bool = false
    ) {
        self.targetID = targetID
        self.targetLang = targetLang
        self.candidate = candidate
        self.scoreCandidate = scoreCandidate
        self.replacementPlan = replacementPlan
        self.isInterpretationAmbiguous = isInterpretationAmbiguous
    }
}

/// Pure selection logic for choosing the best target layout among several candidates.
///
/// Historically auto-fix only ever tried converting the current layout to the *next* layout in the
/// user's cycle and scored that single candidate. With 3+ layouts configured the "next" layout is
/// often the wrong language, producing wrong-direction conversions. This generator instead lets the
/// caller score *every* candidate layout and picks the best by margin, while detecting the case
/// where the top two targets are too close to call (ambiguous) — so the caller can propose rather
/// than silently auto-applying a guessed direction.
enum AutoFixCandidateGenerator {
    struct Selection: Equatable {
        let best: AutoFixTargetCandidate
        let runnerUp: AutoFixTargetCandidate?
        /// True when the top two candidates BOTH clear the replace threshold yet sit within
        /// `separation` of each other — i.e. we cannot confidently pick a direction.
        let isAmbiguous: Bool
    }

    /// Orders candidates by margin (`scoreCandidate - scoreOriginal`) descending, then by absolute
    /// `scoreCandidate` descending, then by input order (stable) for determinism. Returns `nil` when
    /// there are no candidates to choose from.
    static func select(
        candidates: [AutoFixTargetCandidate],
        scoreOriginal: Double,
        threshold: Double,
        separation: Double
    ) -> Selection? {
        guard !candidates.isEmpty else { return nil }

        let ordered = candidates.enumerated().sorted { lhs, rhs in
            let lMargin = lhs.element.scoreCandidate - scoreOriginal
            let rMargin = rhs.element.scoreCandidate - scoreOriginal
            if lMargin != rMargin { return lMargin > rMargin }
            if lhs.element.scoreCandidate != rhs.element.scoreCandidate {
                return lhs.element.scoreCandidate > rhs.element.scoreCandidate
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let best = ordered[0]
        let runnerUp = ordered.count > 1 ? ordered[1] : nil

        var ambiguous = false
        if let runnerUp,
           AutoFixDecision.shouldReplace(
               scoreOriginal: scoreOriginal,
               scoreCandidate: best.scoreCandidate,
               threshold: threshold
           ),
           AutoFixDecision.shouldReplace(
               scoreOriginal: scoreOriginal,
               scoreCandidate: runnerUp.scoreCandidate,
               threshold: threshold
           ),
           abs(best.scoreCandidate - runnerUp.scoreCandidate) < separation {
            ambiguous = true
        }

        return Selection(best: best, runnerUp: runnerUp, isAmbiguous: ambiguous)
    }
}
