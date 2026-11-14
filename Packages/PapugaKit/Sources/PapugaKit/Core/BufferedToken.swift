import Foundation

/// A token collected from the event tap up to a whitespace boundary.
///
/// Edge punctuation is provisional: it can be syntax that must survive a
/// spelling/rule replacement, or a physical key that belongs to a layout
/// conversion. Keeping both the raw text and the split lets the decision layer
/// evaluate both interpretations before any text is mutated.
struct BufferedToken: Equatable {
    let rawText: String
    let keyCodes: [UInt16]
    let core: String
    let leadingEdge: String
    let trailingEdge: String

    init(rawText: String, keyCodes: [UInt16]) {
        self.rawText = rawText
        self.keyCodes = keyCodes

        let characters = Array(rawText)
        var coreStart = characters.startIndex
        while coreStart < characters.endIndex,
              Self.isProvisionalEdgePunctuation(characters[coreStart]) {
            coreStart += 1
        }

        var coreEnd = characters.endIndex
        while coreEnd > coreStart,
              Self.isProvisionalEdgePunctuation(characters[coreEnd - 1]) {
            coreEnd -= 1
        }

        leadingEdge = String(characters[..<coreStart])
        core = String(characters[coreStart..<coreEnd])
        trailingEdge = String(characters[coreEnd...])
    }

    static func normalizedCore(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return BufferedToken(rawText: trimmed, keyCodes: []).core
    }

    func render(correctedCore: String) -> String {
        leadingEdge + correctedCore + trailingEdge
    }

    func replacementPlan(
        correctedCore: String,
        boundary: String,
        reason: ReplacementInterpretationReason
    ) -> ReplacementPlan {
        ReplacementPlan(
            rawSource: rawText,
            correctedCore: correctedCore,
            preservedLeadingPunctuation: leadingEdge,
            preservedTrailingPunctuation: trailingEdge,
            renderedReplacement: render(correctedCore: correctedCore),
            boundary: boundary,
            interpretationReason: reason
        )
    }

    private static func isProvisionalEdgePunctuation(_ character: Character) -> Bool {
        provisionalEdgePunctuation.contains(character)
    }

    private static let provisionalEdgePunctuation: Set<Character> = [
        ",", ".", ";", ":", "?", "!", "…",
        "(", ")", "[", "]", "{", "}", "<", ">",
        "\"", "'", "`", "‘", "’", "“", "”", "«", "»", "‹", "›"
    ]
}

enum ReplacementInterpretationReason: String, Codable, Equatable, Sendable {
    case sameLanguageSpelling
    case customRule
    case layoutFullToken
    case layoutCorePreservingEdges
    case phrase
}

struct ReplacementPlan: Codable, Equatable, Sendable {
    let rawSource: String
    let correctedCore: String
    let preservedLeadingPunctuation: String
    let preservedTrailingPunctuation: String
    let renderedReplacement: String
    let boundary: String
    let interpretationReason: ReplacementInterpretationReason

    var boundaryToReplay: String {
        boundary.isEmpty ? " " : boundary
    }

    var textToType: String {
        renderedReplacement + boundaryToReplay
    }

    var characterCountToDelete: Int {
        rawSource.count + boundaryToReplay.count
    }

    /// Core-only custom rules cannot reproduce a layout mapping that consumed
    /// a punctuation-looking key from either edge of the raw token.
    var canCreateCoreRule: Bool {
        guard interpretationReason == .layoutFullToken else { return true }
        let token = BufferedToken(rawText: rawSource, keyCodes: [])
        return token.leadingEdge.isEmpty && token.trailingEdge.isEmpty
    }
}

struct LayoutInterpretationDecision: Equatable {
    enum Kind: Equatable {
        case replace
        case suggestionOnly
        case rejected
    }

    let kind: Kind
    let suggestions: [ReplacementPlan]

    var replacementPlan: ReplacementPlan? {
        kind == .replace ? suggestions.first : nil
    }

    var isSuggestionOnly: Bool { kind == .suggestionOnly }
    var isRejected: Bool { kind == .rejected }
}

enum LayoutInterpretationPolicy {
    /// - Parameter unverifiable: neither reading is dictionary-attested, but
    ///   no dictionary actually *rejected* them either — there is simply no
    ///   authority for that language (or it has not loaded yet). Distinguishing
    ///   this from a real rejection keeps layout candidates alive for target
    ///   languages macOS has no dictionary for; they come back as
    ///   suggestion-only so they can be offered but never silently applied.
    static func select(
        token: BufferedToken,
        fullMapped: String,
        coreMapped: String,
        fullIsValid: Bool,
        coreIsValid: Bool,
        unverifiable: Bool = false,
        boundary: String
    ) -> LayoutInterpretationDecision {
        let fullPlan = ReplacementPlan(
            rawSource: token.rawText,
            correctedCore: fullMapped,
            preservedLeadingPunctuation: "",
            preservedTrailingPunctuation: "",
            renderedReplacement: fullMapped,
            boundary: boundary,
            interpretationReason: .layoutFullToken
        )
        let corePlan = token.replacementPlan(
            correctedCore: coreMapped,
            boundary: boundary,
            reason: .layoutCorePreservingEdges
        )

        switch (fullIsValid, coreIsValid) {
        case (true, true):
            if fullPlan.renderedReplacement == corePlan.renderedReplacement {
                return LayoutInterpretationDecision(kind: .replace, suggestions: [fullPlan])
            }
            return LayoutInterpretationDecision(kind: .suggestionOnly, suggestions: [fullPlan, corePlan])
        case (true, false):
            return LayoutInterpretationDecision(kind: .replace, suggestions: [fullPlan])
        case (false, true):
            return LayoutInterpretationDecision(kind: .replace, suggestions: [corePlan])
        case (false, false):
            guard unverifiable else {
                return LayoutInterpretationDecision(kind: .rejected, suggestions: [])
            }
            // Offer the reading that at least looks like a word; if both do,
            // the core plan wins because it preserves the user's punctuation.
            let plans = [corePlan, fullPlan].filter {
                WordPlausibility.isWordLike($0.correctedCore)
            }
            guard let best = plans.first else {
                return LayoutInterpretationDecision(kind: .rejected, suggestions: [])
            }
            return LayoutInterpretationDecision(kind: .suggestionOnly, suggestions: [best])
        }
    }
}

/// Safe-default gate for rule sources that no longer carry a full
/// `ReplacementPlan` (legacy history, AI batches, and recommendations).
enum CoreRuleSafety {
    static func canCreateWithoutLayoutInterpretation(
        rawSource: String,
        targetCore: String,
        isLayoutCandidate: Bool
    ) -> Bool {
        let token = BufferedToken(rawText: rawSource, keyCodes: [])
        let hasProvisionalEdges = !token.leadingEdge.isEmpty || !token.trailingEdge.isEmpty
        guard hasProvisionalEdges else { return true }
        if isLayoutCandidate { return false }
        return !AutoFixDecision.isCrossScriptConversion(
            original: token.core,
            candidate: targetCore
        )
    }
}
