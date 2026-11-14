import Foundation

enum MappedSpellingStatus: Equatable {
    case unavailable
    case correct
    case misspelled
}

struct ScoredGuess: Equatable {
    let term: String
    let distance: Int
    let count: Int

    var logFrequency: Double { count > 0 ? log10(1 + Double(count)) : 0 }
}

protocol SpellCheckingClient {
    func isExplicitlyKnown(_ word: String, language: String) -> Bool
    func logFrequency(of word: String, language: String) -> Double
    func isMisspelled(_ word: String, language: String) -> Bool
    func guesses(for word: String, language: String) -> [String]
    func rankedGuesses(for word: String, language: String) -> [ScoredGuess]
    func mappedSpellingStatus(_ word: String, language: String) -> MappedSpellingStatus
}

extension SpellCheckingClient {
    func isExplicitlyKnown(_ word: String, language: String) -> Bool { false }

    func logFrequency(of word: String, language: String) -> Double { 0 }

    func mappedSpellingStatus(_ word: String, language: String) -> MappedSpellingStatus {
        isMisspelled(word, language: language) ? .misspelled : .correct
    }

    func rankedGuesses(for word: String, language: String) -> [ScoredGuess] {
        guesses(for: word, language: language).map { term in
            ScoredGuess(
                term: term,
                distance: SymSpell.damerauLevenshtein(
                    Array(word.lowercased()), Array(term.lowercased())
                ),
                count: 0
            )
        }
    }
}
