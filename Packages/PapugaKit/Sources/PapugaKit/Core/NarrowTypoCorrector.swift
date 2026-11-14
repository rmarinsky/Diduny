import Carbon.HIToolbox
import Foundation

/// The one class of spelling mistake safe enough to fix without asking: a
/// single slip of the fingers — two neighbouring letters swapped, or a key
/// missed for the one beside it — in a word of five letters or more, where the
/// dictionary offers exactly one common word a single edit away. Everything
/// else (missing letters, doubled letters, rare or ambiguous targets, words
/// the user taught Papuga) stays a suggestion.
enum NarrowTypoCorrector {
    /// ANSI letter rows, left to right. Only same-row neighbours count: that
    /// is the slip a finger actually makes, and it keeps the class small.
    private static let rows: [[Int]] = [
        [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T, kVK_ANSI_Y, kVK_ANSI_U,
         kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket],
        [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_J,
         kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_Semicolon, kVK_ANSI_Quote],
        [kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_N, kVK_ANSI_M,
         kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash]
    ]

    static func areNeighbourKeys(_ lhs: UInt16, _ rhs: UInt16) -> Bool {
        rows.contains { row in
            guard let left = row.firstIndex(of: Int(lhs)), let right = row.firstIndex(of: Int(rhs)) else { return false }
            return abs(left - right) == 1
        }
    }

    /// Whether `typed` turns into `intended` by one adjacent transposition or
    /// one neighbouring-key substitution.
    static func isFingerSlip(typed: [Character], intended: [Character], keyCode: (Character) -> UInt16?) -> Bool {
        guard typed.count == intended.count else { return false }
        let differing = typed.indices.filter { typed[$0] != intended[$0] }
        if differing.count == 2, differing[1] == differing[0] + 1 {
            return typed[differing[0]] == intended[differing[1]] && typed[differing[1]] == intended[differing[0]]
        }
        if differing.count == 1,
           let typedKey = keyCode(typed[differing[0]]), let intendedKey = keyCode(intended[differing[0]]) {
            return areNeighbourKeys(typedKey, intendedKey)
        }
        return false
    }

    static func correction(
        for word: String,
        language: String,
        spellChecker: SpellCheckingClient,
        keyCode: (Character) -> UInt16?
    ) -> String? {
        let lowered = word.lowercased()
        let isCapitalized = word == lowered.prefix(1).uppercased() + lowered.dropFirst()
        guard word.count >= 5, word.allSatisfy(\.isLetter), word == lowered || isCapitalized,
              !spellChecker.isExplicitlyKnown(lowered, language: language),
              spellChecker.isMisspelled(lowered, language: language)
        else { return nil }
        let typed = Array(lowered)
        let oneEditAway = Set(spellChecker.rankedGuesses(for: lowered, language: language)
            .map { $0.term.lowercased() }
            .filter { SymSpell.damerauLevenshtein(typed, Array($0)) == 1 })
        // A second word one edit away means the dictionary cannot say which
        // one was meant — that is a question, not a correction.
        guard oneEditAway.count == 1, let intended = oneEditAway.first,
              spellChecker.logFrequency(of: intended, language: language) >= 3,
              isFingerSlip(typed: typed, intended: Array(intended), keyCode: keyCode)
        else { return nil }
        return word == lowered ? intended : intended.prefix(1).uppercased() + intended.dropFirst()
    }
}
