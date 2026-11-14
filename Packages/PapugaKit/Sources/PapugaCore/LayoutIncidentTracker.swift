import Foundation

struct LayoutIncidentToken: Equatable {
    enum Evidence: Equatable {
        case strong
        case neutral
        case contradiction
    }

    let original: String
    let candidate: String
    let boundary: String
    let targetLayoutID: String
    let evidence: Evidence
    /// Caret right after this token's boundary, sampled while it was still true.
    /// Kept per token because a trailing contradiction gets trimmed before
    /// replacement — the anchor then belongs to the last *judged* token, not to
    /// the last one typed.
    let boundaryCaret: Int?

    init(
        original: String,
        candidate: String,
        boundary: String,
        targetLayoutID: String,
        evidence: Evidence,
        boundaryCaret: Int? = nil
    ) {
        self.original = original
        self.candidate = candidate
        self.boundary = boundary
        self.targetLayoutID = targetLayoutID
        self.evidence = evidence
        self.boundaryCaret = boundaryCaret
    }
}

enum LayoutIncidentAppendResult: Equatable {
    case accepted
    case reachedCap
    case wouldExceedCap
    case targetChanged
}

enum LayoutIncidentDecision: Equatable {
    case replace
    case propose
    case discard
}

struct LayoutIncidentTracker: Equatable {
    static let defaultMaxWords = 30
    static let defaultMaxUTF16Length = 300

    private let maxWords: Int
    private let maxUTF16Length: Int
    private(set) var tokens: [LayoutIncidentToken] = []
    private(set) var targetLayoutID: String?

    init(
        maxWords: Int = Self.defaultMaxWords,
        maxUTF16Length: Int = Self.defaultMaxUTF16Length
    ) {
        self.maxWords = max(1, maxWords)
        self.maxUTF16Length = max(1, maxUTF16Length)
    }

    var wordCount: Int { tokens.count }
    var isEmpty: Bool { tokens.isEmpty }
    var trailingBoundary: String { tokens.last?.boundary ?? " " }
    var originalBody: String { body(\.original) }
    var candidateBody: String { body(\.candidate) }

    var isAtSafetyCap: Bool {
        wordCount >= maxWords
            || originalBody.utf16.count >= maxUTF16Length
            || candidateBody.utf16.count >= maxUTF16Length
    }

    var endsSentence: Bool {
        Self.hasSentenceTerminator(originalBody) || Self.hasSentenceTerminator(candidateBody)
    }

    static func isHardBoundary(_ boundary: String) -> Bool {
        boundary == "\r" || boundary == "\n" || boundary == "\t"
    }

    @discardableResult
    mutating func append(_ token: LayoutIncidentToken) -> LayoutIncidentAppendResult {
        if let targetLayoutID, targetLayoutID != token.targetLayoutID {
            return .targetChanged
        }

        let internalBoundaryLength = tokens.last?.boundary.utf16.count ?? 0
        let projectedOriginalLength = originalBody.utf16.count
            + internalBoundaryLength
            + token.original.utf16.count
        let projectedCandidateLength = candidateBody.utf16.count
            + internalBoundaryLength
            + token.candidate.utf16.count
        guard tokens.count + 1 <= maxWords,
              projectedOriginalLength <= maxUTF16Length,
              projectedCandidateLength <= maxUTF16Length else {
            return .wouldExceedCap
        }

        targetLayoutID = token.targetLayoutID
        tokens.append(token)
        return isAtSafetyCap ? .reachedCap : .accepted
    }

    /// Tokens worth judging. A trailing contradiction is the correct word that
    /// *ended* the run — the only position the controller lets one occupy — so
    /// it is the user's real text, never part of the mistake. It is cut before
    /// scoring and before replacement; the run is judged and replaced without it.
    var judgedTokens: [LayoutIncidentToken] {
        var judged = tokens
        while judged.last?.evidence == .contradiction {
            judged.removeLast()
        }
        return judged
    }

    /// The joined run is the unit of judgment: the margin of the whole candidate
    /// phrase over the whole original IS the verdict.
    ///
    /// This replaces quorum voting (strong-token counts and support ratios),
    /// which ignored the phrase score it had already been handed: it demanded
    /// three strong words before acting, so "nj ljhtxs" — weak + strong, phrase
    /// margin ~0.9 — fell through, and the strong half then got replaced alone.
    ///
    /// `hasUnanimousDictionarySupport` is the scorer's blind spot covered from
    /// the other side: for "іудутшву іудусещкі" → "selenide selectors" the
    /// language scorer rates gibberish Cyrillic as confident Ukrainian and the
    /// margin goes negative, while per-word dictionary evidence (every candidate
    /// a real word, every original not) is unanimous. Unanimity earns a
    /// *proposal* only — when the scorer disagrees, nothing is auto-applied.
    ///
    /// `hasContradiction` covers a contradiction that survived trimming (not
    /// currently producible — kept as the safety valve should token flow change):
    /// a run containing a word the user meant is never auto-replaced.
    ///
    /// `hasStrongEvidence`: at least one token in the run is a `.strong` wrong-layout
    /// word (dictionary-backed, or a cross-script conversion of 3+ letters that
    /// already scores as the target language). A run of only short/neutral tokens
    /// ("i", "nj") rests on the joined phrase score alone, which is unreliable for
    /// one or two letters — it earns a proposal at most, never a silent rewrite.
    static func runVerdict(
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double,
        proposalWindow: Double,
        hasContradiction: Bool,
        hasUnanimousDictionarySupport: Bool = false,
        hasStrongEvidence: Bool = true,
        isDictionaryBackedRun: Bool = false
    ) -> LayoutIncidentDecision {
        let margin = scoreCandidate - scoreOriginal
        if margin >= threshold {
            return hasContradiction || !hasStrongEvidence ? .propose : .replace
        }
        if margin >= threshold - proposalWindow {
            // The language scorer underrates short conversational phrases
            // ("я ще раз" lands at 0.32), and a proposal for them is typed over
            // long before anyone reads it. When the dictionary vouches for every
            // real word of the run, the near-threshold margin is corroboration
            // enough to apply — with Undo — instead of asking.
            return isDictionaryBackedRun && !hasContradiction ? .replace : .propose
        }
        if hasUnanimousDictionarySupport, !hasContradiction {
            return .propose
        }
        return .discard
    }

    /// Whether a finalized run may fall back to blind keyboard deletes.
    ///
    /// The blind path deletes backwards from the *live* caret. Once the user has
    /// typed past the run (a trimmed trailing word, an allowlisted word, a cap
    /// overflow) that caret no longer sits after the run, so without a recorded
    /// boundary caret to prove position the deletes would eat the newer text.
    static func allowsBlindReplacement(typedPastRun: Bool, boundaryCaret: Int?) -> Bool {
        !typedPastRun || boundaryCaret != nil
    }

    /// Two or more tokens, at least one dictionary-verified wrong-layout word,
    /// and nothing else but function-word-sized fillers (`z`, `s`, `ot`) —
    /// no long word the dictionary could not confirm.
    static func isDictionaryBackedRun(_ tokens: [LayoutIncidentToken]) -> Bool {
        tokens.count >= 2
            && tokens.contains { $0.evidence == .strong }
            && tokens.allSatisfy { token in
                token.evidence == .strong
                    || (token.evidence == .neutral
                        && BufferedToken(rawText: token.original, keyCodes: []).core.count <= 3)
            }
    }

    static func joinedBody(
        of tokens: [LayoutIncidentToken],
        _ keyPath: KeyPath<LayoutIncidentToken, String>
    ) -> String {
        tokens.enumerated().map { index, token in
            let text = token[keyPath: keyPath]
            guard index < tokens.count - 1 else { return text }
            return text + token.boundary
        }.joined()
    }

    mutating func reset() {
        tokens.removeAll(keepingCapacity: true)
        targetLayoutID = nil
    }

    private func body(_ keyPath: KeyPath<LayoutIncidentToken, String>) -> String {
        Self.joinedBody(of: tokens, keyPath)
    }

    private static func hasSentenceTerminator(_ text: String) -> Bool {
        let ignoredClosers = CharacterSet(charactersIn: "\"'”’)]}")
        let trimmed = text.unicodeScalars
            .reversed()
            .drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) || ignoredClosers.contains($0) })
        guard let last = trimmed.first else { return false }
        return last == "." || last == "!" || last == "?"
    }
}

struct LayoutIncidentTimerState: Equatable {
    /// Defaults used when no cadence estimate is supplied (tests, cold paths).
    /// Live callers pass `TypingCadenceTracker`-derived durations instead.
    static let singleWordGrace: TimeInterval = 0.3
    static let incidentIdleDelay: TimeInterval = 0.6

    enum DueAction: Equatable {
        case applySingleWord
        case finalizeIncident
    }

    private enum Pending: Equatable {
        case singleWord(deadline: TimeInterval)
        case incident(deadline: TimeInterval)
    }

    private var pending: Pending?

    mutating func armSingleWord(at timestamp: TimeInterval, grace: TimeInterval = Self.singleWordGrace) {
        pending = .singleWord(deadline: timestamp + grace)
    }

    mutating func armIncidentIdle(at timestamp: TimeInterval, idle: TimeInterval = Self.incidentIdleDelay) {
        pending = .incident(deadline: timestamp + idle)
    }

    mutating func consumeFastContinuation(at timestamp: TimeInterval) -> Bool {
        guard case .singleWord(let deadline) = pending,
              timestamp < deadline else { return false }
        pending = nil
        return true
    }

    mutating func takeDueAction(at timestamp: TimeInterval) -> DueAction? {
        guard let pending else { return nil }
        let action: DueAction
        let deadline: TimeInterval
        switch pending {
        case .singleWord(let value):
            action = .applySingleWord
            deadline = value
        case .incident(let value):
            action = .finalizeIncident
            deadline = value
        }
        guard timestamp >= deadline else { return nil }
        self.pending = nil
        return action
    }

    mutating func reset() {
        pending = nil
    }
}
