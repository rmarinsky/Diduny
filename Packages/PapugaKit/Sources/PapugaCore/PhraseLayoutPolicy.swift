import Foundation

enum PhraseTokenAssessment: Equatable {
    case keep
    case spellingCandidate(String)
    case layoutCandidate(targetLayoutID: String)
    case ambiguous
}

enum PhraseLayoutPolicy {
    static func assess(
        originalCore: String,
        correctedCore: String,
        sourceLanguage: String,
        targetLanguage: String,
        targetLayoutID: String,
        isAmbiguous: Bool,
        isKnownCorrect: @escaping (String, String) -> Bool
    ) -> PhraseTokenAssessment {
        guard !isAmbiguous, !originalCore.isEmpty, !correctedCore.isEmpty else {
            return .ambiguous
        }

        let spellcheck = isKnownCorrect
        let originalToken = BufferedToken(rawText: originalCore, keyCodes: [])
        let correctedToken = BufferedToken(rawText: correctedCore, keyCodes: [])
        if originalToken.core.isEmpty,
           !correctedToken.core.isEmpty,
           spellcheck(correctedCore, targetLanguage) {
            return .layoutCandidate(targetLayoutID: targetLayoutID)
        }
        if spellcheck(originalCore, sourceLanguage) {
            return .keep
        }
        guard spellcheck(correctedCore, targetLanguage) else {
            return .ambiguous
        }
        guard AutoFixDecision.isCrossScriptConversion(
            original: originalCore,
            candidate: correctedCore
        ) else {
            return .spellingCandidate(correctedCore)
        }
        return .layoutCandidate(targetLayoutID: targetLayoutID)
    }

    static func unanimousTarget(in assessments: [PhraseTokenAssessment]) -> String? {
        guard assessments.count >= 3 else { return nil }
        var target: String?

        for assessment in assessments {
            guard case .layoutCandidate(let candidateTarget) = assessment else {
                return nil
            }
            if let target, target != candidateTarget {
                return nil
            }
            target = candidateTarget
        }

        return target
    }
}
