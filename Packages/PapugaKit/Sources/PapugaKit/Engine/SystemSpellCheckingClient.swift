import AppKit
import Foundation

struct SystemSpellCheckingClient: SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool {
        !AutoFixDecision.isCorrectlySpelled(word, language: language)
    }

    func guesses(for word: String, language: String) -> [String] {
        NSSpellChecker.shared.guesses(
            forWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
    }
}
