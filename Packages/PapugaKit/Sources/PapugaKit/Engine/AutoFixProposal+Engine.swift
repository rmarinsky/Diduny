import Foundation

struct AutoFixProposal: Identifiable, Equatable {
    enum Kind: Equatable {
        case detected
        case customRule
        case spelling
        case compound
    }

    let id = UUID()
    let original: String
    let candidate: String
    let boundary: String
    let fromLayoutID: String
    let targetLayoutID: String
    let scoreOriginal: Double
    let scoreCandidate: Double
    let threshold: Double
    let algorithm: LanguageScorerAlgorithm
    let currentLang: String
    let targetLang: String
    let bundleID: String
    let createdAt: TimeInterval
    let replacementAnchor: TextReplacementAnchor
    let kind: Kind

    /// Canonical presentation record: never substitute an intermediate layout
    /// candidate for the text the user actually saw.
    func decisionObservation(proposalWindow: Double, candidateSeparation: Double,
                             minimumWordLength: Int) -> AutoFixDecisionObservation {
        let token = BufferedToken(rawText: original, keyCodes: [])
        return AutoFixDecisionObservation(
            id: id, source: original, selectedCandidate: candidate,
            originalScore: scoreOriginal,
            effectiveCandidateScore: kind == .compound ? nil : scoreCandidate,
            threshold: threshold, proposalWindow: proposalWindow,
            candidateSeparation: candidateSeparation, minimumWordLength: minimumWordLength,
            algorithm: algorithm, outcome: .proposed,
            reason: kind == .spelling ? AutoFixSkipReason.likelySpellingTypo.rawValue : nil,
            scope: kind == .customRule ? .customRule : (original.contains(where: \.isWhitespace) ? .phrase : .word),
            sourceLayoutID: fromLayoutID, targetLayoutID: targetLayoutID,
            sourceLanguage: currentLang, targetLanguage: targetLang, bundleID: bundleID,
            signalKind: kind == .spelling ? .spellingSuggestion : .proposal,
            candidateOrigin: candidateOrigin,
            proposalContext: .init(kind: String(describing: kind),
                sourceCore: String(token.core.prefix(AutoFixDecisionObservation.maxStoredCharacterCount)),
                leadingPunctuation: String(token.leadingEdge.prefix(AutoFixDecisionObservation.maxStoredCharacterCount)),
                trailingPunctuation: String(token.trailingEdge.prefix(AutoFixDecisionObservation.maxStoredCharacterCount))))
    }

    var margin: Double {
        scoreCandidate - scoreOriginal
    }

    var createsRuleOnAcceptance: Bool {
        kind == .detected
    }

    var changesInputLayout: Bool {
        kind == .detected || kind == .compound
    }

    var candidateOrigin: AutoFixDecisionCandidateOrigin {
        switch kind {
        case .detected: return .keyboardLayout
        case .customRule: return .customRule
        case .spelling: return .spelling
        case .compound: return .keyboardLayout
        }
    }

    var displayTitle: String {
        kind == .spelling || kind == .compound ? "Можливе виправлення" : "Можлива заміна"
    }

    var primaryActionTooltip: String {
        createsRuleOnAcceptance
            ? "Замінити й створити правило. Enter"
            : "Виправити поточний випадок. Enter"
    }

    var neverActionTitle: String {
        kind == .spelling || kind == .compound
            ? "Ніколи не виправляти “\(original)”"
            : "Ніколи не замінювати “\(original)”"
    }
}

struct PendingProposalRecovery: Equatable {
    let proposal: AutoFixProposal
    let expiresAt: TimeInterval

    func isValid(at timestamp: TimeInterval) -> Bool {
        timestamp < expiresAt
    }
}
