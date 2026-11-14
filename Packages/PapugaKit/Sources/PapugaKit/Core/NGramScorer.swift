import Foundation

/// A compact local word/character model. Scores rank lexical evidence; they are
/// not calibrated probabilities. Unseen words cannot outrank attested words on
/// character shape alone. Languages without bundled data retain OS evidence.
final class NGramScorer: LanguageScorer {
    private struct Model {
        var words: [String: Int] = [:]
        var contexts: [String: Double] = [:]
        var triples: [String: Double] = [:]
        var alphabet: Set<Character> = []

        init(words: [(String, Int)]) {
            for (raw, count) in words {
                let word = raw.precomposedStringWithCanonicalMapping.lowercased()
                self.words[word, default: 0] += count
                let weight = log1p(Double(count))
                let characters = Array("^^" + word + "$")
                alphabet.formUnion(characters)
                for end in 2..<characters.count {
                    contexts[String(characters[(end - 2)..<end]), default: 0] += weight
                    triples[String(characters[(end - 2)...end]), default: 0] += weight
                }
            }
        }

        func score(_ word: String) -> Double {
            if let count = words[word] {
                return min(1, 0.9 + log10(1 + Double(count)) / 60)
            }
            let characters = Array("^^" + word + "$")
            var logLikelihood = 0.0
            for end in 2..<characters.count {
                let context = String(characters[(end - 2)..<end])
                let triple = String(characters[(end - 2)...end])
                let probability = ((triples[triple] ?? 0) + 0.1)
                    / ((contexts[context] ?? 0) + 0.1 * Double(alphabet.count + 1))
                logLikelihood += log(probability)
            }
            return min(0.4, exp(logLikelihood / Double(max(1, characters.count - 2))) * 2)
        }
    }

    private static let models: [String: Model] = {
        var models: [String: Model] = [:]
        for language in ["en", "uk"] {
            let words = DictionaryBuilder.loadBundledBase(language: language)
            if !words.isEmpty { models[language] = Model(words: words) }
        }
        return models
    }()
    private let fallback = AppleNLScorer()

    /// Warm once at app startup, before the event tap starts accepting words.
    static func prepare() { _ = models }

    func score(_ text: String, expecting languageCode: String) -> Double {
        guard !text.isEmpty, !languageCode.isEmpty else { return 0 }
        guard let model = Self.models[languageCode] else {
            return fallback.score(text, expecting: languageCode)
        }
        let words = text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return 0 }
        return words.reduce(0) { total, word in
            total + model.score(String(word).trimmingCharacters(in: .punctuationCharacters))
        } / Double(words.count)
    }
}
