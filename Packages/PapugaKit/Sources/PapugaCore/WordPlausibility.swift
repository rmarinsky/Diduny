import Foundation

/// Cheap "is this string a plausible word?" gate. Used to reject garbage
/// suggestions — e.g. a layout conversion of a real Ukrainian word into a
/// consonant-cluster or punctuation soup (`плейрайт → gktqhfqn`, `віджет → dsl;tn`,
/// `репозиторії → htgjpbnjhs]`). A real correction like `кщьфт → roman` passes;
/// gibberish does not.
enum WordPlausibility {
    private static let vowels = Set("aeiouyAEIOUYаеєиіїоуюяёэыАЕЄИІЇОУЮЯЁЭЫ")

    /// Ukrainian is full of apostrophe forms (`п'ять`, `м'ясо`, `об'єкт`,
    /// `здоров'я`, `ім'я`) and hyphenated compounds (`по-перше`, `будь-який`);
    /// English has `don't` and `e-mail`. Demanding that every character be a
    /// letter rejected all of them, which dropped them from candidates and from
    /// domain-vocabulary learning, and let `primaryTarget` override a recorded
    /// apostrophe correction with a layout guess.
    ///
    /// They are legal only *between* letters — a leading or trailing one is
    /// edge punctuation, which `BufferedToken` has already stripped.
    private static let internalConnectors: Set<Character> = ["'", "\u{2019}", "\u{02BC}", "-"]

    static func isWordLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }

        // Letters, plus connectors strictly between letters. Still no digits,
        // and no stray punctuation (`;`, `]`, `.`) or symbols.
        guard let first = trimmed.first, let last = trimmed.last,
              first.isLetter, last.isLetter else { return false }
        var previousWasConnector = false
        for character in trimmed {
            if character.isLetter {
                previousWasConnector = false
                continue
            }
            guard internalConnectors.contains(character) else { return false }
            // No doubled connectors: `a--b`, `can''t`.
            guard !previousWasConnector else { return false }
            previousWasConnector = true
        }

        // Must contain a vowel: kills consonant soup like "gktqhfqn".
        guard trimmed.contains(where: { vowels.contains($0) }) else { return false }

        // No absurd consonant run (real words top out around 5, e.g. "borscht").
        // A connector is a separator: it neither counts as a consonant nor
        // resets the run, so `здоров'я` must not read as one 6-letter cluster.
        var run = 0
        for ch in trimmed {
            if internalConnectors.contains(ch) { continue }
            if vowels.contains(ch) { run = 0 } else {
                run += 1
                if run >= 6 { return false }
            }
        }
        return true
    }
}
