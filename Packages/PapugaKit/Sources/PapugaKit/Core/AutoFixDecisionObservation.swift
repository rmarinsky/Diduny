import Foundation

enum AutoFixDecisionSignalKind: String, Codable, CaseIterable, Identifiable {
    case replacement
    case proposal
    case nearThreshold
    case spellingSuggestion
    case layoutIncident
    case mutationFailure

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .replacement: return "Заміна"
        case .proposal: return "Підказка"
        case .nearThreshold: return "Біля порога"
        case .spellingSuggestion: return "Орфографія"
        case .layoutIncident: return "Розкладка"
        case .mutationFailure: return "Збій"
        }
    }
}

enum AutoFixDecisionCandidateOrigin: String, Codable {
    case keyboardLayout
    case spelling
    case customRule

    var displayName: String {
        switch self {
        case .keyboardLayout: return "Розкладка"
        case .spelling: return "Орфографія"
        case .customRule: return "Власне правило"
        }
    }
}

enum AutoFixDecisionMarginBand: String, Codable, Hashable {
    case unavailable
    case farNegative
    case nonPositive
    case belowWindow
    case nearThreshold
    case metThreshold
}

struct AutoFixDecisionAggregate: Codable, Equatable, Identifiable {
    let day: Date
    let reason: String?
    let scope: AutoFixDecisionObservation.Scope
    let outcome: AutoFixDecisionObservation.Outcome
    let marginBand: AutoFixDecisionMarginBand
    var count: Int

    var id: String {
        [
            day.timeIntervalSince1970.description,
            reason ?? "none",
            scope.rawValue,
            outcome.rawValue,
            marginBand.rawValue
        ].joined(separator: "|")
    }

    init(observation: AutoFixDecisionObservation, calendar: Calendar = .current) {
        day = calendar.startOfDay(for: observation.timestamp)
        reason = observation.reason
        scope = observation.scope
        outcome = observation.outcome
        marginBand = observation.aggregateMarginBand
        count = 1
    }
}

struct AutoFixScoredCandidate: Codable, Equatable, Identifiable {
    let text: String
    let targetLayoutID: String
    let language: String
    let score: Double

    var id: String { "\(targetLayoutID):\(text)" }

    init(text: String, targetLayoutID: String, language: String, score: Double) {
        self.text = AutoFixDecisionObservation.truncated(text)
        self.targetLayoutID = targetLayoutID
        self.language = language
        self.score = score
    }
}

struct AutoFixDecisionObservation: Codable, Equatable, Identifiable {
    static let maxStoredCharacterCount = 80

    enum Outcome: String, Codable, CaseIterable, Identifiable {
        case replaced
        case proposed
        case ruleApplied
        case skipped

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .replaced: return "Замінено"
            case .proposed: return "Запропоновано"
            case .ruleApplied: return "Правило"
            case .skipped: return "Без заміни"
            }
        }

        var systemImage: String {
            switch self {
            case .replaced: return "checkmark.circle.fill"
            case .proposed: return "lightbulb.fill"
            case .ruleApplied: return "wand.and.stars"
            case .skipped: return "minus.circle"
            }
        }
    }

    enum Scope: String, Codable {
        case word
        case phrase
        case customRule

        var displayName: String {
            switch self {
            case .word: return "Слово"
            case .phrase: return "Фраза"
            case .customRule: return "Власне правило"
            }
        }
    }

    struct ProposalContext: Codable, Equatable {
        let kind: String
        let sourceCore: String
        let leadingPunctuation: String
        let trailingPunctuation: String
    }

    /// Nil on older records. The observation ID is the proposal_id in resolution events.
    let proposalContext: ProposalContext?
    let id: UUID
    let timestamp: Date
    let source: String
    let selectedCandidate: String?
    let candidates: [AutoFixScoredCandidate]
    let originalScore: Double?
    let rawCandidateScore: Double?
    let effectiveCandidateScore: Double?
    let confidence: Double?
    let threshold: Double
    let proposalWindow: Double
    let candidateSeparation: Double
    let minimumWordLength: Int
    let algorithm: LanguageScorerAlgorithm
    let outcome: Outcome
    let reason: String?
    let scope: Scope
    let sourceLayoutID: String?
    let targetLayoutID: String?
    let sourceLanguage: String?
    let targetLanguage: String?
    let bundleID: String?
    let signalKind: AutoFixDecisionSignalKind?
    let candidateOrigin: AutoFixDecisionCandidateOrigin?
    /// Captured incident tokens contribute only to anonymous tuning aggregates. This prevents
    /// inferred near-threshold signals from leaking individual words while a sentence is active.
    let aggregateOnly: Bool?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: String,
        selectedCandidate: String? = nil,
        candidates: [AutoFixScoredCandidate] = [],
        originalScore: Double? = nil,
        rawCandidateScore: Double? = nil,
        effectiveCandidateScore: Double? = nil,
        confidence: Double? = nil,
        threshold: Double,
        proposalWindow: Double,
        candidateSeparation: Double,
        minimumWordLength: Int,
        algorithm: LanguageScorerAlgorithm,
        outcome: Outcome,
        reason: String? = nil,
        scope: Scope,
        sourceLayoutID: String? = nil,
        targetLayoutID: String? = nil,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        bundleID: String? = nil,
        signalKind: AutoFixDecisionSignalKind? = nil,
        candidateOrigin: AutoFixDecisionCandidateOrigin? = nil,
        aggregateOnly: Bool = false,
        proposalContext: ProposalContext? = nil
    ) {
        self.proposalContext = proposalContext
        self.id = id
        self.timestamp = timestamp
        self.source = Self.truncated(source)
        self.selectedCandidate = selectedCandidate.map(Self.truncated)
        self.candidates = candidates
        self.originalScore = originalScore
        self.rawCandidateScore = rawCandidateScore
        self.effectiveCandidateScore = effectiveCandidateScore
        self.confidence = confidence.map { min(1, max(0, $0)) }
        self.threshold = threshold
        self.proposalWindow = proposalWindow
        self.candidateSeparation = candidateSeparation
        self.minimumWordLength = minimumWordLength
        self.algorithm = algorithm
        self.outcome = outcome
        self.reason = reason
        self.scope = scope
        self.sourceLayoutID = sourceLayoutID
        self.targetLayoutID = targetLayoutID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.bundleID = bundleID
        self.signalKind = signalKind
        self.candidateOrigin = candidateOrigin
        self.aggregateOnly = aggregateOnly
    }

    var margin: Double? {
        guard let originalScore, let effectiveCandidateScore else { return nil }
        return effectiveCandidateScore - originalScore
    }

    var resolvedConfidence: Double? {
        if let confidence { return confidence }
        if outcome == .ruleApplied || scope == .customRule || candidateOrigin == .customRule {
            return 1
        }
        guard candidateOrigin == .spelling,
              let selectedCandidate else { return nil }
        let distance = AutoFixDecision.spellingEditDistance(
            source.lowercased(),
            selectedCandidate.lowercased()
        )
        return AutoFixDecision.spellingConfidence(
            original: source,
            suggestion: selectedCandidate,
            editDistance: distance
        )
    }

    var thresholdGap: Double? {
        margin.map { $0 - threshold }
    }

    var clearedReplacementThreshold: Bool {
        thresholdGap.map { $0 >= 0 } ?? false
    }

    var isInsideProposalWindow: Bool {
        guard let margin else { return false }
        return margin > 0
            && margin < threshold
            && threshold - margin <= proposalWindow
    }

    var resolvedSignalKind: AutoFixDecisionSignalKind? {
        if let signalKind { return signalKind }
        switch outcome {
        case .replaced, .ruleApplied:
            return .replacement
        case .proposed:
            return candidateOrigin == .spelling ? .spellingSuggestion : .proposal
        case .skipped:
            break
        }
        if Self.mutationFailureReasons.contains(reason ?? "") {
            return .mutationFailure
        }
        // A valid word in the active source language is a completed safety check, not a
        // tuning signal. Keep only its anonymous daily aggregate even when a cross-layout
        // candidate happens to land inside the proposal window.
        if reason == AutoFixSkipReason.originalIsRealWord.rawValue {
            return nil
        }
        if isInsideProposalWindow {
            return .nearThreshold
        }
        return nil
    }

    var isReviewableSignal: Bool {
        aggregateOnly != true && resolvedSignalKind != nil
    }

    /// The history table is intentionally narrower than persisted tuning data: it shows only
    /// a proposed or completed mutation with a concrete, different replacement candidate.
    var isDisplayableHistorySignal: Bool {
        guard isReviewableSignal,
              outcome != .skipped,
              let selectedCandidate,
              !selectedCandidate.isEmpty else {
            return false
        }
        return selectedCandidate.caseInsensitiveCompare(source) != .orderedSame
    }

    var aggregateMarginBand: AutoFixDecisionMarginBand {
        guard let margin else { return .unavailable }
        if margin <= -0.5 { return .farNegative }
        if margin <= 0 { return .nonPositive }
        if margin >= threshold { return .metThreshold }
        return isInsideProposalWindow ? .nearThreshold : .belowWindow
    }

    static func truncated(_ text: String) -> String {
        guard text.count > maxStoredCharacterCount else { return text }
        return String(text.prefix(maxStoredCharacterCount - 1)) + "…"
    }

    private static let mutationFailureReasons: Set<String> = [
        AutoFixSkipReason.targetChanged.rawValue,
        AutoFixSkipReason.targetUnverifiable.rawValue,
        AutoFixSkipReason.replacementNotCommitted.rawValue
    ]
}

struct AutoFixDecisionSummary: Equatable {
    let total: Int
    let calculated: Int
    let replaced: Int
    let proposed: Int
    let skipped: Int
    let belowThreshold: Int
    let averageBelowThresholdGap: Double?

    init(entries: [AutoFixDecisionObservation]) {
        total = entries.count
        let margins = entries.compactMap(\.margin)
        let belowThresholdGaps = entries.compactMap(\.thresholdGap).filter { $0 < 0 }
        calculated = margins.count
        replaced = entries.filter { $0.outcome == .replaced || $0.outcome == .ruleApplied }.count
        proposed = entries.filter { $0.outcome == .proposed }.count
        skipped = entries.filter { $0.outcome == .skipped }.count
        belowThreshold = belowThresholdGaps.count
        averageBelowThresholdGap = belowThresholdGaps.isEmpty
            ? nil
            : belowThresholdGaps.reduce(0, +) / Double(belowThresholdGaps.count)
    }
}
